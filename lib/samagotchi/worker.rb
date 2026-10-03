# frozen_string_literal: true

require "fileutils"

require_relative "events"
require_relative "session"
require_relative "session_inbox"
require_relative "turn_note"
require_relative "context_note"
require_relative "worker_idle_exit"
require_relative "session_manager"
require_relative "archive_store"
require_relative "log"
require_relative "turn_flow"
require_relative "continue_offer"
require_relative "iteration_limit"
require_relative "session_commands"
require_relative "model_profile"

module Samagotchi
  # The loop of a background session worker, once it owns the session (see
  # SessionManager.run_session_loop, which takes the OwnerLock around #run).
  #
  # It runs the session's Engine and Bridge, takes queued prompts from the
  # input dir one turn at a time, and returns when nobody has used it for the
  # idle-exit timeout. A failed turn is rolled back and its prompt handed back
  # (:prompt_restored), as in the REPL, and the loop goes on. A stop marked on
  # disk exits the process; an error outside a turn marks the session and
  # exits with 1.
  #
  # The file IPC stays behind SessionInbox's functions (find_new_input_files,
  # claim_input_file, ...) and the Bridge behind SessionManager.start_bridge,
  # which specs stub as seams.
  #
  # The loop sleeps on a Waker, which the Bridge wakes when it queues a turn
  # or a command, and the reminder callback when it queues one. A fallback
  # tick picks up input written by another process (the web's
  # write_turn_input fallback) and runs the stop-on-disk and idle-exit checks.
  #
  # Session commands (SessionCommands: /model, /models, !rollback, !cmd,
  # /continue) run on the loop between turns, before any queued prompt. One
  # taken while a turn runs (at an iteration boundary, or right after the
  # turn) is refused as busy.
  class Worker
    FALLBACK_TICK_SECONDS = 5
    # How much of a command's output goes into its :command_ran.
    COMMAND_OUTPUT_LIMIT = 4096
    BUSY_OUTPUT = "busy: wait for the turn to end"

    # Wakes the worker loop. Whoever queues work writes it first and wakes
    # after, and #wait drains every wake before the loop looks for work: a
    # wake drained with the others was for work the loop is about to see,
    # and one that comes later stays queued for the next #wait. So no wake is
    # lost, and a burst of them costs one pass.
    class Waker
      def initialize
        @queue = Thread::Queue.new
      end

      def wake
        @queue << true
        nil
      end

      # @return [Boolean] true when woken, false when the timeout passed
      def wait(timeout)
        woken = !@queue.pop(timeout: timeout).nil?
        @queue.clear
        woken
      end
    end

    # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
    # @param poll_interval [Numeric, nil] seconds between fallback ticks
    def initialize(session_id:, state_dir:, session_dir:, idle_exit_minutes: nil, poll_interval: nil)
      @session_id = session_id
      @state_dir = state_dir
      @session_dir = session_dir
      @idle_exit_minutes = idle_exit_minutes
      @poll_interval = poll_interval || FALLBACK_TICK_SECONDS
      @waker = Waker.new
      @command_queue = Thread::Queue.new
      # The client_id of a client that asked the worker to exit (POST /exit).
      @exit_requested = nil
      @exit_requested_by = nil
      # Set as it leaves: nothing happened in the session (#discard?).
      @discard = false
    end

    # Whether the session was empty as the worker left it, so the caller
    # deletes it once the lock is free (SessionManager.run_session_loop
    # checks again then).
    def discard? = @discard

    # What a new session starts on (and /model resets to); nil before #run.
    attr_reader :default_model

    # @return [Symbol] :idle_exit, :exit_requested when a client asked it
    #   to exit (Bridge POST /exit), :stopped when the session was stopped
    #   (chi stop), :crashed when the loop raised (the session is marked
    #   errored); SessionManager.run_session_loop turns it into the exit
    def run
      @session = Session.load(@session_id, state_dir: @state_dir)
      drop_dead_question
      @engine = build_engine
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      @engine.session = @session
      @turn_flow = TurnFlow.new(engine: @engine)
      @continue_offer = ContinueOffer.new(engine: @engine, turn_flow: @turn_flow, run_turn: method(:run_engine_turn),
                                          max_iterations: method(:max_iterations))
      # A recap written while a continue offer waits says the turn stopped
      # unfinished (before the idle jobs start).
      @engine.recap&.awaiting_continue = -> { @turn_flow.awaiting_continue? }
      # The seq of the last turn's end event: a command queued before it was
      # queued while that turn ran.
      @turn_end_seq = 0
      @engine.subscribe(observer: lambda { |event|
        @turn_end_seq = event[:event_seq] if Events::TURN_END.include?(event[:type])
      })
      # /model's default is the config's, as in the REPL; the Engine started
      # on the session's model.
      @default_model = ModelProfile.required_model_name(nil)
      @commands = SessionCommands.new(engine: @engine, turn_flow: @turn_flow,
                                      default_model: @default_model, registry: @engine.command_registry,
                                      save: ->(session) { session.save(state_dir: @state_dir) })
      # Start the shared idle scheduler so the worker can trigger turns when
      # reminders are due (even with no user input).
      @engine.start_idle

      @bridge = SessionManager.start_bridge(engine: @engine, state_dir: @state_dir, session_id: @session_id,
                                            on_input: -> { @waker.wake },
                                            on_command: lambda { |command|
                                              next start_anytime_command(command) if anytime_command?(command[:line])

                                              # Called with the event log held: the
                                              # count says which turn ends came before it.
                                              @command_queue << command.merge(after_seq: @engine.event_count)
                                              @waker.wake
                                            },
                                            on_exit_request: method(:exit_request),
                                            # Decided again as it leaves (a note may still come in).
                                            exit_discards: method(:empty_session?))
      # What failed to load and what plugins showed as they loaded, now that
      # a UI can be there (a late one gets them in the snapshot).
      @engine.announce_load_events!
      @idle_exit = WorkerIdleExit.new(
        engine: @engine, bridge: @bridge,
        timeout_minutes: @idle_exit_minutes || SessionManager.config_idle_exit_minutes,
        input_pending: -> { !@command_queue.empty? || !SessionInbox.find_new_input_files(@session_dir).empty? },
        awaiting_continue: -> { @turn_flow.awaiting_continue? }
      )

      begin
        # A session stopped before this worker took the lock (e.g. a stop
        # right after create) must not run its initial prompt.
        return :stopped if stopped_on_disk?
        # Plugins' slow setup (chi.init: an MCP server's first start), in
        # the background, shown by the UIs; a turn waits only for the ones
        # that bring tools.
        @engine.start_init_tasks!
        loop do
          # Check if the session was externally marked as stopped. Not
          # stopped_on_disk?, which reads a vanished file as "not stopped":
          # a session file deleted under a running worker crashes it here
          # instead of being saved back by its next turn.
          return :stopped if Session.load(@session_id, state_dir: @state_dir).status == Session::STATUS_STOPPED

          # Commands queued before a prompt run first (a /continue sent
          # before a new prompt still answers the offer).
          next if run_queued_commands

          # Between turns, so the next turn (the first one too) sees them.
          absorb_notes

          if (prompt = take_initial_prompt)
            run_prompt(prompt, nil) unless initial_command(prompt)
            next
          end

          input_files = SessionInbox.find_new_input_files(@session_dir)
          if input_files.empty?
            next if run_due_reminders
            return left(:idle_exit) if @idle_exit.due? && leave_idle
            return left(:exit_requested) if @exit_requested && leave_on_request

            @waker.wait(@poll_interval)
            next
          end

          input_files.sort.each do |input_file|
            # A stop between two queued turns leaves the rest queued.
            break if stopped_on_disk?

            absorb_notes
            run_input_file(input_file)
          end
        end
      rescue StandardError => e
        # Its stderr is /dev/null: the log is the only trace of why.
        Log.exception(:worker, "crashed", e)
        Session.mark_error(@session_id, reason: e.message, state_dir: @state_dir)
        :crashed
      ensure
        # The anytime commands finish and the plugins' services stop (a
        # server process), whatever the way out; the Bridge last, so a
        # command's command_ran still reaches its UI on a crash.
        @engine&.shutdown
        @bridge&.stop
      end
    end

    private

    def build_engine
      waker = @waker
      engine = nil
      engine = Samagotchi::Engine.new(
        model_name: @session.model_name,
        model_typed: @session.model_typed,
        # The session's --memory and --mute lists: the same prompt on every
        # (re)spawn.
        memories: @session.preloaded_memory_names,
        muted_memories: @session.muted_memory_names,
        reminders: {
          callback: lambda { |due_names|
            # A reminder is due: the loop runs a reminder turn for it once
            # nothing else is queued (#run_due_reminders).
            engine.note_due_reminders(due_names)
            waker.wake
          }
        }
      )
      # The attached TUI and the web answer approvals; with none attached
      # one waits, like ask_user_question.
      engine.interface = :worker
      engine.guardrail_state_dir = @state_dir if @state_dir
      engine.session_state_dir = @state_dir if @state_dir
      engine
    end

    # A question saved by a worker that died while it waited (an
    # ask_user_question, an approval, a hook's question): the turn that
    # asked is gone, so nobody can answer it, and left in the file it
    # would keep the hub's "needs you" badge on for good. Dropped and saved
    # before the Engine and the Bridge exist (no question lock, no events).
    def drop_dead_question
      return unless @session.pending_question

      Log.info(:worker, "dead_question_dropped", id: @session.pending_question[:id])
      @session.pending_question = nil
      @session.save(state_dir: @state_dir)
    end

    # spawn_session hands the first prompt over in last_prompt, but
    # last_prompt also records every later turn's prompt (and mark_error's
    # reason), so only a session with no conversation yet has one pending; a
    # resumed session must not replay its last turn. Taken once.
    # @return [String, nil]
    def take_initial_prompt
      return nil if @initial_prompt_taken

      @initial_prompt_taken = true
      # A context note may have come before the first prompt ran.
      return nil unless @session.messages.all? { |m| ContextNote.note?(m) } && !@session.last_prompt.to_s.strip.empty?

      prompt = @session.last_prompt
      @session.last_prompt = ""
      @session.save(state_dir: @state_dir)
      prompt
    end

    # A session command sent as a message (chi send -m "/model x", a web
    # page's first message) runs as the command, as the Bridge does for a
    # POST /turn; an unknown /word stays a prompt. Queued: the loop's next
    # pass runs it.
    # @return [Boolean] whether +text+ was one
    def queue_as_command(text, origin)
      return false unless @engine.command_registry.command?(text.to_s)

      @bridge.queue_command(text, client_id: origin&.dig(:client_id))
      true
    end

    # The first prompt as a command: the session was saved as running for a
    # turn that won't run.
    # @return [Boolean] whether it was one
    def initial_command(prompt)
      return false unless queue_as_command(prompt, nil)

      @session.status = Session::STATUS_IDLE
      save_session
      true
    end

    # Add the queued context notes to the conversation (between turns only,
    # on this thread), save, then delete their files: a crash before the
    # delete leaves them claimed, and Engine#add_context_note skips a note
    # the saved conversation already holds. Not activity: a note alone
    # neither starts a turn nor keeps an idle worker up.
    def absorb_notes
      files = SessionInbox.find_new_note_files(@session_dir)
      return if files.empty? || stopped_on_disk?

      claimed = files.filter_map { |file| SessionInbox.claim_note_file(file) }
      claimed.each do |file|
        note = SessionInbox.read_note(file)
        @engine.add_context_note(@session, note) if note
      end
      @session.save(state_dir: @state_dir)
      claimed.each { |file| FileUtils.rm_f(file) }
    end

    def run_input_file(input_file)
      claimed_file = SessionInbox.claim_input_file(input_file)
      return unless claimed_file

      begin
        message, origin, no_interrupt, images = SessionInbox.read_input(claimed_file)
        return if message.to_s.strip.empty?
        return if Array(images).empty? && queue_as_command(message, origin)

        run_prompt(message, origin, no_interrupt: !!no_interrupt, images: images || [])
      ensure
        FileUtils.rm_f(claimed_file)
      end
    end

    # @param no_interrupt [Boolean] an offer this turn makes keeps it for
    #   its continue turn
    # @param images [Array<Hash>] the prompt's image refs ({file:, name:})
    def run_prompt(prompt, origin, no_interrupt: false, images: [])
      user_input(origin&.dig(:client_id))
      @continue_offer.drop(origin)
      @turn_flow.before_prompt_turn
      @merged_this_turn = []
      run_engine_turn(prompt, origin: origin, max_iterations: max_iterations(no_interrupt),
                              images: images) do |result, error|
        if error
          # The Engine announced :turn_failed (with the error's one line).
          restore_failed_turn([[prompt, origin, images], *@merged_this_turn], error: error)
        else
          @continue_offer.after_turn(result, no_interrupt: no_interrupt)
        end
      end
    end

    # A due reminder runs as a continue turn, as in the REPL: Engine#run_turn
    # injects the reminders as a tail system message, and no user message is
    # added. A prompt's turn may have injected them already (a stale latch):
    # then there is nothing to run.
    # @return [Boolean] whether a reminder turn ran
    def run_due_reminders
      return false if @engine.due_reminder_names.empty?

      @engine.clear_due_reminder_names!
      return false unless @engine.reminders_due?

      @continue_offer.drop({ client_id: SessionManager::REMINDER_CLIENT_ID })
      # A failure has no prompt to hand back (the Engine announced
      # :turn_failed). The offer went before the turn
      # (ContinueOffer#drop); either way the rollback window closes.
      run_engine_turn(nil, continue: true, origin: { client_id: SessionManager::REMINDER_CLIENT_ID },
                           max_iterations: IterationLimit.for) { @turn_flow.after_reminder_turn }
      true
    end

    def max_iterations(no_interrupt) = IterationLimit.for(no_interrupt: no_interrupt)

    # @return [Boolean] whether any command ran
    def run_queued_commands
      ran = false
      while (command = next_command)
        run_command(command)
        ran = true
      end
      ran
    end

    # A command queued while a turn ran is refused (S1), not run after it:
    # at the turn's iteration boundaries (mid_turn: all of them), and when
    # it ends (the ones queued before its end event; later ones run next).
    def refuse_queued_commands(mid_turn: false)
      later = []
      while (command = next_command)
        if mid_turn || command[:after_seq].to_i < @turn_end_seq
          announce_command(command, status: "busy", output: BUSY_OUTPUT, changed: [])
        else
          later << command
        end
      end
      later.each { |command| @command_queue << command }
    end

    def next_command
      @command_queue.pop(true)
    rescue ThreadError
      nil
    end

    def run_command(command)
      awaiting = @continue_offer.awaiting?
      result, shown = run_command_line(command)
      resolved = @continue_offer.resolved?(awaiting, result)
      @engine.synchronize_events do
        @continue_offer.announce_resolved(result, command) if resolved
        announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed))
        shown.each { |event| @engine.announce(event) }
      end
      save_session unless Array(result.changed).empty?
      if resolved
        user_input(command[:client_id])
        @continue_offer.resolved(result)
      end
      @continue_offer.run_continue_turn(command) if result.resume
    end

    # @return [Array(SessionCommands::Result, Array<Hash>)] the result, and
    #   the cards and notices it showed, held: they follow its command_ran,
    #   as its output
    def run_command_line(command)
      result, shown = @engine.holding_announcements do
        @commands.run(command[:line])
      rescue StandardError => e
        SessionCommands::Result.new(status: :error, output: "#{command[:line].split.first}: #{e.message}", changed: [])
      end
      [result || SessionCommands::Result.new(status: :error, output: "not a session command", changed: []), shown]
    end

    def anytime_command?(line) = @engine.command_registry.lookup(line)&.anytime == true

    # An anytime command (/help, a plugin's /btw; D8) runs now, on its own
    # thread, never queued behind a turn: it is never busy. The Bridge calls
    # this with the event log held, so its command_ran (announced when it
    # finishes) comes after its command_queued. The cards it shows go out at
    # once (btw's "thinking…" card), after its command_queued, which the
    # UIs draw its line at (Engine#running_anytime). Its handler reads
    # copies (ctx.messages) and shows things through ctx only; nothing is
    # saved.
    def start_anytime_command(command)
      @engine.spawn_anytime do
        result = begin
          @engine.running_anytime { @commands.run(command[:line]) }
        rescue StandardError => e
          SessionCommands::Result.new(status: :error, output: "#{command[:line].split.first}: #{e.message}", changed: [])
        end
        result ||= SessionCommands::Result.new(status: :error, output: "not a session command", changed: [])
        announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                  anytime: true)
      rescue StandardError => e
        Log.warn(:worker, "anytime_command_failed", line: command[:line], error: e.class.name, msg: e.message)
      end
    end

    # @param anytime [Boolean] an anytime command's: its line was shown at
    #   its command_queued already
    def announce_command(command, status:, output:, changed:, anytime: false)
      text = output.to_s
      event = { type: :command_ran, command_id: command[:command_id], client_id: command[:client_id], line: command[:line],
                status: status, output: text[0, COMMAND_OUTPUT_LIMIT], changed: changed.map(&:to_s),
                model_name: @engine.effective_model_name }
      event[:anytime] = true if anytime
      event[:card] = true if command[:card]
      event[:output_truncated] = true if text.length > COMMAND_OUTPUT_LIMIT
      @engine.announce(event)
    end

    # One Engine turn, the same for a prompt, a reminder and a continue:
    # the session shows as running to readers of the file (the web's
    # session list; the Engine resets it to idle when it ends), commands
    # queued while it ran are refused, then the caller's block takes the
    # result (or the error the Engine announced as :turn_failed), the
    # answer goes to the output file and the session is saved.
    # @yieldparam result [Object, nil] Engine#run_turn's, nil on a failure
    # @yieldparam error [StandardError, nil]
    def run_engine_turn(prompt, **turn_args)
      @session.status = Session::STATUS_RUNNING
      @session.save(state_dir: @state_dir)
      begin
        result = @engine.run_turn(@session, prompt, pending_input: pending_input_drain, **turn_args)
      rescue StandardError => e
        error = e
      ensure
        refuse_queued_commands
      end
      yield result, error
      response = result&.output
      SessionInbox.write_output(@session_dir, response) unless response.nil? || response.strip.empty?
      save_session
    end

    # Back to the conversation before the failed turn, as the REPL does (so
    # failed prompts don't pile up as consecutive user messages), and each
    # prompt it took (its own and any merged into it) goes back to its
    # sender, who can send it again. The rollback and the announcements are
    # one step of the event log: a snapshot shows the failed turn's messages
    # or the restored ones, never the one without the other.
    # @param prompts [Array<Array(String, Hash|nil, Array|nil)>] [prompt,
    #   origin, images] (a web client gets its image chips back)
    # @param error [Exception, nil] what failed: its one line stays in the
    #   conversation as a turn note
    # Not saved here: run_engine_turn saves after its block.
    def restore_failed_turn(prompts, error: nil)
      note = error && TurnNote.failed(error.respond_to?(:summary) ? error.summary : error.message, restored: true)
      @engine.synchronize_events do
        @turn_flow.prompt_turn_failed(note: note)
        prompts.each do |prompt, origin, images|
          restored = { type: :prompt_restored, prompt: prompt, origin: origin }
          restored[:images] = images unless Array(images).empty?
          @engine.announce(restored)
        end
      end
    end

    # Shared mid-turn steering drain: claims any input files that arrive
    # while a turn is running and hands them to the agentic loop so
    # follow-ups merge at the next iteration boundary instead of waiting
    # for the turn to end. claim_input_file is atomic (rename), so a file
    # consumed mid-turn simply fails the outer loop's later claim with
    # ENOENT → nil. No double-processing risk.
    #
    # Runs on the turn thread; it announces who sent the merged input so
    # every live UI can attribute it.
    def pending_input_drain
      @pending_input_drain ||= lambda do
        # An iteration boundary: tell whoever sent a command now that it waits.
        refuse_queued_commands(mid_turn: true)
        # A line with images runs as its own next turn (steering merges text
        # only), and so does anything queued after it, to keep the order.
        files = SessionInbox.find_new_input_files(@session_dir).sort
                            .take_while { |input_file| !SessionInbox.input_has_images?(input_file) }
        merged = files.filter_map do |input_file|
          claimed_file = SessionInbox.claim_input_file(input_file)
          next unless claimed_file

          begin
            prompt, origin = SessionInbox.read_input(claimed_file)
            prompt = prompt.to_s.strip
            prompt.empty? ? nil : [prompt, origin]
          ensure
            FileUtils.rm_f(claimed_file)
          end
        end
        merged.each { |_prompt, origin| user_input(origin&.dig(:client_id)) }
        unless merged.empty?
          @engine.announce(type: :input_merged, count: merged.size, origins: merged.filter_map(&:last))
          @merged_this_turn.concat(merged)
        end
        merged.map(&:first)
      end
    end

    # Check again with the event log held, which the Bridge holds while it
    # queues a POST /turn, then close the Bridge so no client can queue one
    # after the check, and stop the idle jobs (reminder callback, recap).
    # A client connecting from here on finds no worker: `chi --attach` fails
    # and the web stream answers 503 (a small window, left as is).
    # @return [Boolean] false when something came in since #due?
    def leave_idle
      @engine.synchronize_events do
        next false unless @idle_exit.due?

        @bridge&.stop
        @engine.stop_idle
        log_idle_exit
        true
      end
    end

    # Bridge POST /exit, on a Bridge thread with the event log held.
    # +delete+: the session is deleted after (/exit --delete), so no recap.
    # @return [Symbol, nil] what keeps the worker up, nil when it will leave
    def exit_request(client_id, delete: false)
      # The Bridge serves before the idle-exit policy exists.
      return :starting unless @idle_exit

      hold = @idle_exit.hold_for_request(requester: client_id)
      return hold if hold

      @exit_requested = true
      @exit_requested_by = client_id
      @exit_deletes = delete
      @waker.wake
      nil
    end

    # #leave_idle for an exit a client asked for: check again with the event
    # log held (a prompt may have come in since), then close the Bridge and
    # stop the idle jobs. Other clients' streams no longer hold: the asker's
    # may not have closed yet, and a UI joining now finds the worker gone
    # (:stream_closed), the window #leave_idle has too.
    # @return [Boolean] false when something came in since the request
    def leave_on_request
      @engine.synchronize_events do
        hold = @idle_exit.hold_for_request(requester: @exit_requested_by, streams: false)
        if hold
          @exit_requested = nil
          Log.info(:worker, "exit_held", reason: hold)
          next false
        end

        @bridge&.stop
        @engine.stop_idle
        Log.info(:worker, "exit_requested", by: @exit_requested_by || "a client")
        true
      end
    end

    # @return [Symbol] +result+, with #discard? decided and, for a session
    #   kept, its recap written: the Bridge is closed and the idle jobs are
    #   stopped by now, and nothing waits on this (the TUI has detached). A
    #   `chi send` meanwhile is picked up after the exit (run_session_loop);
    #   a `chi --attach` finds no Bridge until then.
    def left(result)
      @discard = empty_session?
      write_recap_on_leave unless @discard || (result == :exit_requested && @exit_deletes)
      result
    end

    def write_recap_on_leave
      written = @engine.write_recap_now
      Log.info(:worker, "recap_on_leave") if written
    rescue StandardError => e
      Log.warn(:worker, "recap_on_leave_failed", error: e.class.name, msg: e.message)
    end

    # Memory used before any turn saved it lives only in the Engine.
    def empty_session?
      SessionManager.discardable?(@session_id, state_dir: @state_dir, default_model: @default_model,
                                               used_memory_names: @engine.used_memory_names)
    end

    def log_idle_exit
      Log.info(:worker, "idle_exit", idle_s: @idle_exit.idle_seconds.round)
    end

    # A human's input (ArchiveStore.user_input?) un-archives the session;
    # a delegate's, a plugin's or a reminder's doesn't.
    def user_input(client_id)
      ArchiveStore.user_input(@session_id, state_dir: @state_dir) if ArchiveStore.user_input?(client_id)
    end

    def stopped_on_disk?
      SessionManager.stopped_on_disk?(@session_id, state_dir: @state_dir)
    end

    # Save the session unless it was stopped meanwhile: the stop (chi stop,
    # from another process) saved its status, and this save would write
    # the worker's over it.
    def save_session
      @session.save(state_dir: @state_dir) unless stopped_on_disk?
    end
  end
end
