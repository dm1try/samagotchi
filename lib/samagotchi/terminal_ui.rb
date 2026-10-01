# frozen_string_literal: true

require "json"
require "fileutils"
require "io/console"
require "reline"

require_relative "model_profile"
require_relative "turn_note"
require_relative "config"
require_relative "context_note"
require_relative "cancellation_controller"
require_relative "llm/errors"
require_relative "host_registry"
require_relative "kernel_loop"
require_relative "session"
require_relative "owner_lock"
require_relative "engine"
require_relative "tools/memory"
require_relative "output_formatter"
require_relative "turn_flow"
require_relative "session_commands"
require_relative "terminal_ui/attached_view"
require_relative "terminal_ui/between_turns"
require_relative "terminal_ui/event_renderer"
require_relative "terminal_ui/formatting"
require_relative "terminal_ui/input_support"
require_relative "terminal_ui/image_input"
require_relative "terminal_ui/plain_surface"
require_relative "terminal_ui/live_region"
require_relative "terminal_ui/question_prompt"
require_relative "terminal_ui/repl_input"
require_relative "terminal_ui/status_row"
require_relative "log"

module Samagotchi
  # Loaded on first use: session_manager requires this file (its worker
  # process loads the whole UI stack through it), a require cycle otherwise.
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # The in-process terminal front end (`chi --no-shared`, `chi scratch`,
  # --verbose, --non-interactive): it owns one session and its Engine, runs
  # an optional -p prompt (--non-interactive: that one turn and out), then the REPL,
  # where the user types, the model answers and tools run inline. The
  # attached terminal (a worker's session) is TerminalUI::AttachedLoop.
  class TerminalUI
    include Formatting
    include InputSupport

    SCRATCH_ARCHIVE_REFUSED = "a scratch session is deleted when you leave; nothing to archive"
    # The prompt while a question waits for its answer (its choices are in
    # the notes slot).
    QUESTION_PROMPT = "? "
    REMINDER_PENDING_POLL_INTERVAL = 0.5
    # What a command sent during a turn gets, as from a worker (Worker::BUSY_OUTPUT).
    COMMAND_BUSY = "busy: wait for the turn to end"
    # /detach is the attached terminal's; the REPL owns its session.
    REPL_DETACH_NOTE = "(not attached: this session runs in this terminal; /exit ends it)"
    IMAGE_LINE_WAITS = "(a line with images runs as the next turn)"

    # Raised when another process (a `chi web` worker or another chi) owns the
    # session this TUI was asked to run.
    class SessionBusy < StandardError; end
    # --resume with an id that has no saved session.
    class SessionNotFound < StandardError; end

    # What prints between turns (cards, notices, init lines, an idle recap):
    # announced on other threads, printed at the open prompt.
    # @return [BetweenTurns]
    attr_reader :between_turns
    # The session's Engine: the REPL drives it inline (#run_engine_turn).
    # @return [Engine]
    attr_reader :engine

    # ── System prompts (delegated to Engine) ─────────────────────────────────
    def self.system_prompt_for(profile)
      Engine.system_prompt_for(profile)
    end

    # @param scratch [Boolean] `chi scratch`: a new session that is deleted
    #   however the REPL ends, saves no memories and writes no recap
    def initialize(prompt: nil, client: nil, host_registry: nil, profile: nil, session_id: nil, no_interrupt: false, no_default_input: false, model_name: nil, memories: [], muted_memories: [], non_interactive: false, surface: nil,
                   spinner_tick_interval: AttachedView::TICK_INTERVAL, spinner_clock: nil, scratch: false)
      @scratch        = scratch
      @prompt         = prompt
      @default_model_name = ModelProfile.required_model_name(nil)
      # As typed: the Engine applies an alias where it resolves the model.
      flag_model_name = model_name.to_s.strip.empty? ? nil : ModelProfile.required_model_name(model_name)
      @effective_model_name = flag_model_name || @default_model_name
      @host_registry  = host_registry || Samagotchi::HostRegistry.new
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = @host_registry.resolve(@effective_model_name).client
      # Own the session before loading it, so a worker can't write a turn
      # between the load and the lock that this TUI would later save over.
      # An unknown id is refused before the claim, which would leave an
      # empty session dir behind.
      if session_id && !Session.exist?(session_id)
        raise SessionNotFound, "Session not found: #{session_id}"
      end
      claim_session!(session_id) if session_id
      @resume_session = session_id ? Session.load(session_id) : nil
      if @resume_session
        # --model overrides resumed session's model (runtime only, default unchanged)
        if flag_model_name
          @effective_model_name = flag_model_name
        else
          @effective_model_name = @resume_session.model_name.to_s.strip.empty? ? @default_model_name : @resume_session.model_name
          @resumed_model_typed = @resume_session.model_typed
        end
        # Re-resolve client after resume may change effective model
        @client = @host_registry.resolve(@effective_model_name).client
      end
      # The model it starts on names a configured host (a bad default.model
      # doesn't matter when --model or the session picks another).
      ModelProfile.check_host!(@effective_model_name, hosts: @host_registry.entries)
      # Only a caller's profile goes in; otherwise the Engine resolves one
      # for the effective model and hands it to the kernel.
      @kernel         = KernelLoop.new(client: @client, profile: profile, reminder_store: Samagotchi::ReminderStore.new)
      @no_default_input = no_default_input
      @non_interactive = non_interactive
      # --memory and --mute, with a resumed session's own lists first: a
      # session started attached with mutes keeps them here.
      @requested_memories = Array(memories)
      @muted_memory_names = Array(muted_memories)
      if @resume_session
        @requested_memories = (@resume_session.preloaded_memory_names + @requested_memories).uniq
        @muted_memory_names = (@resume_session.muted_memory_names + @muted_memory_names).uniq
      end
      # Every terminal write goes through the surface. The REPL swaps in a
      # live region when the terminal can show one (#assist_loop), unless it
      # was given a surface to draw on.
      @surface = surface || PlainSurface.new
      @surface_given = !surface.nil?
      # The turn view is the attached TUI's, and so is the status row; both
      # move to the live region with the surface (#use_surface). A
      # spinner_tick_interval of nil: no ticker thread, and a spinner_clock
      # fixes the frames (specs that compare exact frames).
      view_options = { tick_interval: spinner_tick_interval }
      view_options[:clock] = spinner_clock if spinner_clock
      @view = AttachedView.new(@surface, **view_options)
      @status_row = StatusRow.new(@surface)
      @renderer = EventRenderer.new(@view)
      # Cards, notices and a recap announced between turns, printed by the
      # main thread at the open prompt (#poll_input_with_reminder_check).
      @between_turns = BetweenTurns.new(surface: @surface, view: @view, renderer: @renderer,
                                        turn_running: -> { @engine.turn_running? }, quiet: @non_interactive)
      @render_event = ->(event) { handle_stream_event(event) }
      @engine         = Engine.new(
        client: client,
        host_registry: @host_registry,
        profile: profile,
        session_id: session_id,
        no_interrupt: no_interrupt,
        # nil: the config default, unchecked here (the model the REPL starts
        # on is checked above, and --model may make the default moot).
        model_name: nil,
        memories: @requested_memories,
        muted_memories: @muted_memory_names,
        kernel: @kernel,
        recap: scratch ? nil : recap_config,
        scratch: scratch,
        reminders: {
          callback: lambda { |due_names|
            # When a reminder is due, queue a synthetic turn that
            # run_assist_loop checks before read_input. The synthetic turn
            # uses an empty prompt so the agent can see
            # [SYSTEM: REMINDERS DUE] and act on them.
            @engine.note_due_reminders(due_names)
          }
        }
      )
      # -p without --non-interactive drops into the REPL, which can answer
      # an approval; --non-interactive can't, so an approval there denies.
      @engine.interface = @non_interactive ? :non_interactive : :repl
      @turn_flow = TurnFlow.new(engine: @engine)
      # A recap written while a continue offer waits says the turn stopped
      # unfinished. (Answering at the prompt is typing: activity already.)
      @engine.recap&.awaiting_continue = -> { @turn_flow.awaiting_continue? }
      @commands = SessionCommands.new(engine: @engine, turn_flow: @turn_flow, default_model: @default_model_name,
                                      registry: @engine.command_registry)
      # Runtime --model flag or resumed session: switch the Engine (client,
      # kernel profile) without persisting the default.
      @engine.switch_model!(@effective_model_name, typed: @resumed_model_typed) if @effective_model_name != @default_model_name
      # Render an idle session-recap via the cursor-safe background writer; the
      # detector itself is Engine-owned (see Engine#recap) and opt-in.
      @recap_handle = @engine.subscribe(observer: ->(event) { @between_turns.take_recap(event) })
      @question_handle = @engine.subscribe(observer: ->(event) { handle_question_event(event) })
      @card_handle = @engine.subscribe(observer: ->(event) { @between_turns.observe(event) })
      # The REPL renders events from here on: the load warnings and notices
      # now (at the first prompt), and the plugins' slow setup in the
      # background. A --non-interactive run leaves both to its turn.
      unless @non_interactive
        @engine.announce_load_events!
        @engine.start_init_tasks!
      end
      # Synchronous TUI handler for in-turn ask_user_question: the turn thread IS the
      # REPL thread (run_engine_turn runs Engine#run_turn inline), so we must render
      # and collect input on the SAME thread without parking on a second thread.
      @engine.set_question_sync_handler do |pending|
        # render_question_widget records the choice via Engine#answer_question,
        # which Engine.request_question reads back once this handler returns.
        render_question_widget(pending)
        nil
      end
    end

    # Single dispatch for all entrypoints (interactive REPL, --prompt,
    # --non-interactive, --resume). Builds the working session and its seed
    # messages once, runs a single prompt turn when -p/--prompt is given
    # (auto-executing it, then saving), then either exits when there is no
    # follow-up REPL (--non-interactive) or drops into the REPL carrying the
    # post-turn conversation.
    # @return [Symbol, nil] :turn_failed when lines came from a pipe and a
    #   turn failed (bin/chi exits 1)
    def run
      # --non-interactive with no --prompt is a harmless no-op exit: build
      # nothing and return (no transient session, no banner).
      return if @non_interactive && @prompt.nil?

      session = @resume_session || @engine.store_model!(Session.new_session(
        mode: "assist",
        model_name: @effective_model_name,
        working_directory: Dir.pwd,
        preloaded_memory_names: @requested_memories,
        muted_memory_names: @muted_memory_names,
        scratch: @scratch
      ))
      claim_session!(session.id) unless @owner_lock
      # Saved at once, so a process killed before its first turn leaves a
      # file the sweep knows to delete.
      session.save if @scratch
      # Attach before building the prompt so it can name the session id.
      @engine.session = session
      messages = messages_for(session)

      if @prompt && @non_interactive
        # Headless / CI mode: run directly without TTY rendering.
        ArchiveStore.user_input(session.id, state_dir: Session.default_state_dir)
        result = @engine.run_turn(
          session,
          @prompt,
          on_event: nil,
          max_iterations: 1000,
          cancel_controller: nil,
          images: ImageInput.extract(@prompt)
        )
        if empty_answer?(result)
          # Nothing to print: say so on stderr and fail, so a script that
          # pipes the answer doesn't take the silence for one.
          session.save
          warn EMPTY_ANSWER_ERROR
          exit 1
        end
        @surface.commit(result.output)
        session.save
        return
      end

      assist_loop(session: session, messages: messages)
      # After the idle layer has stopped: nothing writes the session now.
      case exit_action
      when :scratch then nil # deleted below, however the REPL ended
      when :delete then delete_after_exit(session)
      when :discard then discard_after_exit(session)
      when :archive then archive_after_exit(session)
      else keep_after_exit(session)
      end
      # Lines from a pipe (`chi -p X </dev/null`): a failed turn fails the run.
      :turn_failed if @piped_turn_failed
    ensure
      # However it ends (the early returns too; the Engine was built in
      # #initialize): the anytime commands finish, the plugins' services
      # stop (a server process).
      @engine&.shutdown
      # A scratch session goes on every way out: /exit, Ctrl-D, an error,
      # SIGTERM or SIGHUP (Ruby raises those here). Only kill -9 leaves it
      # to the sweep.
      delete_scratch(session, quiet: @non_interactive || !$!.nil?) if @scratch && session
    end

    EMPTY_ANSWER_ERROR = "chi: the model gave an empty answer"

    # A -p --non-interactive turn that ended with no answer (the empty-answer
    # retries used up): no text, or the chat loop's placeholder.
    def empty_answer?(result)
      return false if result.respond_to?(:canceled?) && result.canceled?
      return false if result.respond_to?(:resumable?) && result.resumable?

      result.output.to_s.strip.empty? || (result.respond_to?(:empty_answer?) && result.empty_answer?)
    end

    # Delete the scratch session, the last thing the REPL does. Quiet after
    # a one-shot or on the way out of an error or a signal.
    def delete_scratch(session, quiet:)
      @owner_lock&.release
      @owner_lock = nil
      SessionManager.delete_session(session.id)
      @surface.commit("Scratch session deleted.") unless quiet
    rescue StandardError => e
      warn "Scratch session #{session.id} was not deleted (#{e.message}): chi sessions delete #{session.id}"
    end

    # The session stays: the recap first, then the resume line, last.
    def keep_after_exit(session)
      recap_after_exit
      @surface.commit("\nContinue session: chi --resume #{session.id}")
    end

    # The recap for coming back: written before the REPL ends (it has to
    # wait, same process), when there is something new to recap. Ctrl-C
    # gives up on it.
    def recap_after_exit
      @engine.write_recap_now(on_start: -> { @surface.commit("writing a recap…") })
    rescue Interrupt
      nil
    end

    # Nothing happened in the session (SessionManager.discardable?). The
    # REPL saves only after a turn and keeps /model in its Engine, so a
    # session never saved is judged from memory, and one on another model
    # than the default (/model, --model) is kept.
    def discard_on_exit?(session)
      SessionManager.discardable?(session.id, default_model: @default_model_name, model_name: @effective_model_name,
                                              used_memory_names: @engine.used_memory_names, unsaved: session)
    end

    # A session left empty: give it up and delete it, one quiet line.
    def discard_after_exit(session)
      @owner_lock&.release
      @owner_lock = nil
      SessionManager.delete_session(session.id)
      @surface.commit("The session was empty, so it is discarded.")
    rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError, SystemCallError => e
      @surface.commit("Continue session: chi --resume #{session.id} (the empty session was not discarded: #{e.message})")
    end

    # /exit --delete: give up the session, then delete it for good.
    def delete_after_exit(session)
      @owner_lock&.release
      @owner_lock = nil
      SessionManager.delete_session(session.id)
      @surface.commit("Deleted session #{session.id}.")
    rescue SessionManager::DeleteRefused, SessionManager::OwnedByTUI, ArgumentError, SystemCallError => e
      @surface.commit("Session #{session.id} was not deleted (#{e.message}): chi sessions delete #{session.id}")
    end

    # /archive: give up the session, then archive it (hidden from the lists,
    # kept for good). An empty one is discarded instead (#discard_on_exit?).
    def archive_after_exit(session)
      @owner_lock&.release
      @owner_lock = nil
      SessionManager.archive_session(session.id)
      @surface.commit("Archived session #{session.id}. chi sessions list --archived finds it.")
    rescue SessionManager::ArchiveRefused, SessionManager::OwnedByTUI, ArgumentError, SystemCallError => e
      @surface.commit("Session #{session.id} was not archived (#{e.message}): chi sessions archive #{session.id}")
    end

    # Take the session's OwnerLock for this process's lifetime: the TUI runs
    # its own Engine, so no worker may run the session meanwhile.
    # @raise [SessionBusy] when a worker or another TUI owns it
    def claim_session!(session_id)
      session_dir = Session.session_dir(session_id)
      @owner_lock = OwnerLock.acquire(session_dir, kind: "tui", wait: 1.0)
      return @owner_lock if @owner_lock

      owner = OwnerLock.owner(session_dir)
      where = owner&.tui? ? "another chi" : "a `chi web` worker"
      raise SessionBusy, "Session #{session_id} is open in #{where} (pid #{owner&.pid || "unknown"}). " \
                         "Close it there first."
    end

    # Build the seed messages for the working session.
    #
    # Resumed sessions keep their prior conversation (only the system-prompt
    # slot is replaced); fresh sessions start with just the system prompt.
    # Prints a one-line banner so the user sees which session they're in.
    def messages_for(session)
      system_message = { role: "system", content: seed_system_prompt }
      if @resume_session
        messages = ContextNote.with_system_head(session.messages.dup, system_message)
        @surface.commit("Resumed session: #{session.id}")
        saved = @engine.saved_recap
        @surface.commit(recap_block(saved[:text], turns_since: saved[:turns_since])) if saved
      elsif @scratch
        messages = [system_message]
        @surface.commit("Scratch session: nothing is kept, it is deleted when you leave.")
      else
        messages = [system_message]
        @surface.commit("Session: #{session.id}")
      end
      messages
    end

    # Interactive REPL loop. Session seed + messages are built by #run and
    # threaded in here (so --prompt / --resume share one code path). The
    # session's conversation is the single working copy: turns go through
    # Engine#run_turn and out-of-turn edits through Engine's messages API.
    # The checkpoint and continue state live in @turn_flow (shared with
    # session workers). The session is persisted at the end of every turn.
    def run_assist_loop(session:, messages:)
      session.messages = messages
      @engine.session = session
      # Steering: lines submitted at the open prompt during a turn
      # (#steer_line), merged by the kernel (#drain_steering).
      @pending_input_queue = PendingInputQueue.new
      open_repl_input

      loop do
        if @exit_after_turn
          # Ctrl-D or exit came during a turn: the lines sent before it still
          # run (all queued: the prompt closed at Ctrl-D), then the REPL ends.
          input = queued_line
          break if input.nil?
        else
          # Drain any pending ask_user_question first — it has priority over reminders and
          # must be rendered on the REPL thread (turn thread is parked on Engine Monitor).
          drain_pending_question?

          # A due reminder runs its turn now, with the prompt open (on a
          # terminal): the turn's output commits above it and whatever is typed
          # there stays.
          unless @engine.due_reminder_names.empty?
            run_reminder_turn(session)
            @turn_flow.after_reminder_turn
            next
          end
          input = @prompt
          @prompt = nil if input
          if input.nil?
            input = poll_input_with_reminder_check(awaiting_continue: @turn_flow.awaiting_continue?)
            # A reminder fell due: run it at the top, with the prompt still open.
            next if input == :due
          end
        end
        break if input.nil?
        local = local_command(input)
        if local == :exit
          @delete_on_exit ||= SessionCommands.delete_on_exit?(input)
          break
        end
        if local == :archive
          next @surface.commit(SCRATCH_ARCHIVE_REFUSED) if @scratch

          @archive_on_exit = true
          break
        end
        # Not an answer to a continue offer either.
        next detach_note if local == :detach

        # /stats and /recap run; the offer stays open.
        if @turn_flow.awaiting_continue? && !%i[stats recap].include?(local)
          answer_continue_offer(session, input)
        else
          # The ? read left no echo: show what ran.
          @surface.commit("#{paint(QUESTION_PROMPT, 33)}#{input}") if @turn_flow.awaiting_continue?
          run_input_line(session, input)
        end
      end

      close_repl_input
      @discard_on_exit = !@delete_on_exit && discard_on_exit?(session)
    end

    # Run one REPL turn (a prompt, or a continue/reminder turn with nil) through
    # Engine#run_turn, rendering via @renderer.
    # @param images [Array<Hash>] the prompt's `@path` images ({path:})
    def run_engine_turn(session, prompt, continue: false, max_iterations: 100, images: [])
      cancellation_controller = CancellationController.new
      @active_cancel_controller = cancellation_controller
      @renderer.begin_turn
      # The row shows the turn's model (a -p turn runs before any read).
      refresh_status_row
      # A prompt the user typed brings an archived session back to the lists.
      ArchiveStore.user_input(session.id, state_dir: Session.default_state_dir) if prompt && !continue
      with_steering do
        @engine.run_turn(
          session,
          prompt,
          on_event: @render_event,
          max_iterations: max_iterations,
          cancel_controller: cancellation_controller,
          pending_input: method(:drain_steering),
          continue: continue,
          images: images
        )
      end
    rescue Interrupt
      # Engine kept the prompt in the session and emitted :turn_canceled
      # (the renderer's line).
      cancellation_controller&.cancel!(:ctrl_c)
      cancelled_result_from(session.messages, reason: :ctrl_c)
    ensure
      @active_cancel_controller = nil
      @view.finish_thinking_spinner
    end

    # How the REPL leaves its session once the loop ended (#run): :scratch
    # (deleted however it ends), :delete (/exit --delete), :discard (left
    # empty), :archive (/archive) or :keep.
    def exit_action
      if @scratch then :scratch
      elsif @delete_on_exit then :delete
      elsif @discard_on_exit then :discard
      elsif @archive_on_exit then :archive
      else :keep
      end
    end

    # Ctrl-D or /exit came during a turn: the REPL ends after it.
    def exit_after_turn? = @exit_after_turn == true

    private

    # Interactive REPL loop. Session seed + messages are built by #run and
    # threaded in here (so --prompt / --resume share one code path). The
    # working session is persisted at the end of every turn.
    def assist_loop(session:, messages:)
      load_persistent_history

      # queue_default_input self-guards on @resume_session, so calling it
      # unconditionally preserves the original fresh-session prefill behavior.
      # Skip the default input prefill when a user-provided --prompt was used —
      # the explicit prompt means the user is in command and shouldn't see the
      # default input ("Please " etc.) on the next REPL prompt.
      queue_default_input if @prompt.nil?

      # The idle layer (reminders + optional recap) is Engine-owned; start the
      # shared scheduler for this REPL and stop it on exit. with_activity_hook
      # resets the shared inactivity clock when a prompt opens and on each key.
      with_live_region do
        with_interrupt_arbiter do
          @engine.start_idle
          with_activity_hook do
            run_assist_loop(session: session, messages: messages)
          ensure
            @engine.stop_idle
          end
        end
      end
    end

    # Ctrl-C while a Reline read owns stdin: Reline's INT trap catches it, so
    # the REPL hears of it through RelineSeam. A running turn is cancelled and
    # the prompt stays as typed; with no turn running it is Reline's Ctrl-C.
    # (With no read open, Ctrl-C stays an Interrupt on the turn's thread.)
    def with_interrupt_arbiter
      return yield unless RelineSeam.supported?

      RelineSeam.install
      previous = RelineSeam.interrupt_handler
      RelineSeam.interrupt_handler = method(:cancel_turn_from_prompt)
      begin
        yield
      ensure
        RelineSeam.interrupt_handler = previous
      end
    end

    # @return [Boolean] a running turn was cancelled
    def cancel_turn_from_prompt
      controller = @active_cancel_controller
      return false unless controller

      controller.cancel!(:ctrl_c)
      true
    end

    # Draw the REPL on a live region (a Screen, with Reline's prompt in it)
    # when the terminal can show one; plain output otherwise, or on the
    # surface the UI was given.
    def with_live_region
      screen = LiveRegion.open unless @surface_given
      return yield unless screen

      plain = @surface
      use_surface(screen)
      begin
        yield
      ensure
        # Nothing may draw on the screen once it is closed: the view moves
        # off it, then its ticker ends.
        use_surface(plain)
        @view.stop
        LiveRegion.close(screen)
      end
    end

    def use_surface(surface)
      @surface = surface
      @view.surface = surface
      @status_row.surface = surface
      @between_turns.surface = surface
    end

    # An answer at the ? prompt of a continue offer. A valid one closes the
    # offer's choices and leaves one line; an invalid one gets its error.
    def answer_continue_offer(session, input)
      answer = @commands.continue_answer(input)
      if answer.decision == :invalid
        # The read left no echo: the line shows above its error.
        @surface.commit("#{paint(QUESTION_PROMPT, 33)}#{input}")
      else
        sync_continue_slot(false)
        @surface.commit(QuestionSlot.continue_summary(input.to_s.strip.empty? ? "yes" : input.to_s.strip, paint: method(:paint)))
      end
      return show_command_result(answer) unless answer.resume

      @turn_flow.before_continue_turn
      begin
        result = run_engine_turn(session, nil, continue: true)
      rescue LLM::ProviderError
        # The renderer showed the failure (:turn_failed).
        @surface.commit(turn_end_hint("continue prompt preserved"))
        return
      end
      finish_turn(session, result, continue: true)
    end

    # A line at the main prompt: a command, or a prompt for a turn.
    def run_input_line(session, input)
      return if input.empty?

      # /model, /models, !rollback, !cmd, /continue (shared with workers);
      # an anytime command's cards print as it shows them (btw's
      # "thinking…" before the answer).
      command = if command_registry.lookup(input)&.anytime
                  @engine.running_anytime { @commands.run(input) }
                else
                  @commands.run(input)
                end
      if command
        show_command_result(command)
        persist_recent_history(input) if command.shell
        return
      end
      return if show_local_command(input)

      @turn_flow.before_prompt_turn
      persist_recent_history(input)
      begin
        # Engine#run_turn injects due reminders as a tail message, appends
        # the prompt, and renders through @renderer via on_event.
        result = run_engine_turn(session, input, images: ImageInput.extract(input))
      rescue LLM::ProviderError, ImageStore::Error => e
        # Engine closed the turn (:turn_failed), which the renderer showed.
        # An @path image that can't be used fails the turn the same way.
        summary = e.respond_to?(:summary) ? e.summary : e.message
        # The model reads why on its next turn. An image that couldn't be
        # used, or that the host refused, never reached it: no note for that
        # (a first turn refused that way leaves the session empty, as before).
        note = TurnNote.failed(summary, restored: true) if e.is_a?(LLM::ProviderError) && !e.is_a?(LLM::VisionUnsupported)
        @turn_flow.prompt_turn_failed(note: note)
        # The Engine saved the failed turn; the file follows the rollback.
        save_session(session) if note
        if piped_input?
          # Nobody can edit a restored prompt, and Reline would hand it back
          # as the next line: the turn would run again and again. It failed;
          # the exit status says so.
          @piped_turn_failed = true
        else
          @surface.commit(turn_end_hint(restore_prompt_for_retry(input)))
        end
        return
      end
      finish_turn(session, result, continue: false)
    end

    # After a prompt or continue turn: TurnFlow keeps the checkpoint and the
    # continue offer; the REPL saves and tells the user.
    def finish_turn(session, result, continue:)
      if result.respond_to?(:canceled?) && result.canceled?
        outcome = @turn_flow.after_turn(result, continue: continue)
        # A cancelled continue is back where it started, the offer still open.
        return if outcome == :continue_cancelled

        # Ctrl-C on a fresh turn. The kernel salvaged completed tool calls
        # and the partial assistant reply (marked [interrupted]) into
        # result.conversation, so progress is preserved by default — the
        # user's next message continues from it. !rollback restores the
        # pre-turn checkpoint for an explicit full discard (the renderer's
        # hint under :turn_canceled says so).
        save_session(session) if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
        return
      end

      # The REPL keeps the kernel's conversation as-is (no [No response]
      # placeholder), so /continue resumes from the tool results.
      session.messages = result.conversation
      @turn_flow.after_turn(result, continue: continue)
      save_session(session)
    end

    def save_session(session)
      @engine.store_model!(session)
      session.save
    end

    # A !cmd shows its own output; everything else is the model> line.
    def show_command_result(result)
      if result.shell
        @surface.commit(result.output)
        @surface.commit("")
      elsif !result.output.nil?
        @surface.commit("\nmodel> #{result.output}")
      end
      sync_model_mirrors if result.changed.include?(:model)
    end

    # The status line and the next session save read these.
    def sync_model_mirrors
      @effective_model_name = @engine.effective_model_name
      @default_model_name = @commands.default_model
    end

    # Engine's built-once system prompt (the one run_turn sends).
    def seed_system_prompt = @engine.system_prompt

    def read_input(awaiting_continue:)
      refresh_status_row

      if awaiting_continue
        sync_continue_slot(true)
        input = Reline.readline(paint(QUESTION_PROMPT, 33), true)
        return nil if input.nil?

        return input.strip
      end

      read_prompt_line(paint("> ", 92))
    rescue Interrupt
      nil
    end

    # The synthetic turn for due reminders (Engine#run_turn injects them as
    # a tail message). The hints row says which, while it runs.
    def run_reminder_turn(session)
      names = @engine.due_reminder_names
      @engine.clear_due_reminder_names!
      # A normal turn may already have injected them (a stale latch): no
      # empty synthetic turn then (it duplicated output).
      return unless @engine.reminders_due?

      # A pending continue offer goes, as for a new prompt (the worker's rule).
      if @turn_flow.before_reminder_turn
        sync_continue_slot(false)
        @surface.commit(QuestionSlot.continue_summary("(dropped: a reminder ran)", paint: method(:paint)))
      end
      @surface.commit(reminder_line(names))
      hint = "#{reminder_line(names)} · Ctrl-C cancels it"
      @surface.set_slot(:hints, [color_output? ? paint(hint, 90) : hint])
      result = nil
      begin
        result = run_engine_turn(session, nil, continue: true)
        @prompt = nil
      rescue LLM::ProviderError
        nil # the renderer showed the failure; back to the prompt
      ensure
        @surface.clear_slot(:hints)
      end
      canceled = result.respond_to?(:canceled?) && result.canceled?
      if result && !canceled
        session.messages = result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
        @engine.store_model!(session)
        session.save
      end
      # The synthetic turn is activity: the next reminder waits a full
      # interval (without it they fired back to back).
      @engine.record_activity
    end

    # The next line from the prompt, or :due when a reminder falls due first.
    # On a terminal the prompt stays open the whole session (#open_repl_input):
    # a reminder turn runs with it (and anything typed in it) still there, and
    # a line submitted meanwhile comes next. Ctrl-C during a turn reaches
    # #cancel_turn_from_prompt.
    def poll_input_with_reminder_check(awaiting_continue:)
      return :due unless @engine.due_reminder_names.empty?
      # Specs and pipes: a plain blocking read.
      unless @repl_input
        @between_turns.flush_cards
        return read_input(awaiting_continue: awaiting_continue)
      end

      if @idle_status_due
        @idle_status_due = false
        refresh_status_row
      end
      sync_continue_slot(awaiting_continue)
      @repl_input.sync_prompt
      loop do
        @between_turns.flush_recap
        @between_turns.flush_cards
        kind, line = @repl_input.pop(timeout: REMINDER_PENDING_POLL_INTERVAL)
        if kind
          # What the line does may change the status (/model, a turn).
          @idle_status_due = true
          # Ctrl-C at an idle prompt ends the REPL, as Ctrl-D does.
          return kind == :line ? line : nil
        end
        return :due unless @engine.due_reminder_names.empty?
      end
    end

    # On a terminal: one read for the whole session, on a LineReader.
    def open_repl_input
      return unless STDIN.tty? && $stdin.tty?

      @idle_status_due = false
      refresh_status_row
      @repl_input = ReplInput.new(prompt: method(:repl_prompt_text), read: method(:read_repl_line), surface: @surface).start
    end

    def close_repl_input
      @repl_input&.stop
      @repl_input = nil
    end

    # The main prompt, or ? when a continue offer waits and no turn runs.
    def repl_prompt_text
      return paint("> ", 92) if @active_cancel_controller || !@turn_flow.awaiting_continue?

      paint(QUESTION_PROMPT, 33)
    end

    # The notes slot shows a continue offer's choices while it waits.
    def sync_continue_slot(shown)
      if shown
        return if @continue_slot

        @continue_slot = true
        @surface.set_slot(:notes, QuestionSlot.continue_offer(@turn_flow.offer&.dig(:context), paint: method(:paint)))
      elsif @continue_slot
        @continue_slot = false
        @surface.clear_slot(:notes)
      end
    end

    # One read on the reader thread (ReplInput): the multiline read with Tab
    # completion at the main prompt, a plain line for the continue offer and
    # a question's ? prompt. +prefill+ is typed in first.
    def read_repl_line(prompt, prefill)
      queue_input_prefill(prefill) if prefill
      return read_prompt_line(prompt) if prompt == paint("> ", 92)

      read = -> { with_next_input_prefill { Reline.readline(prompt, true) }&.strip }
      # A question's answer leaves only its summary line.
      prompt == paint(QUESTION_PROMPT, 33) ? RelineSeam.without_echo(&read) : read.call
    end

    # Lines come from a pipe or a file (`chi -p X </dev/null`, `echo … | chi`),
    # not a terminal: no prompt is restored for a retry.
    def piped_input? = !$stdin.tty?

    # A failed prompt goes back into the input for a retry.
    # @return [String] what the failed-turn line says about it
    def restore_prompt_for_retry(input)
      unless @repl_input
        queue_input_prefill(input)
        return "prompt restored for retry"
      end
      @repl_input.prefill(input) ? "prompt restored for retry" : "the failed prompt is in the input history (↑)"
    end

    # The id of the terminal's own command +input+ is (:exit, :archive,
    # :detach, :stats, :recap; SessionCommands registers them), or nil.
    def local_command(input) = command_registry.lookup_local(input)&.id

    # /stats and /recap, which show and change nothing (at the prompt, a
    # continue offer's ? prompt, or during a turn).
    # @return [Boolean] whether +input+ was one
    def show_local_command(input)
      case local_command(input)
      when :stats then @surface.commit("\nmodel> session stats:\n#{format_session_metrics(@engine.stats_snapshot)}")
      when :recap then @surface.commit("\nmodel> #{handle_recap_command}")
      else return false
      end
      true
    end

    # /recap: the saved recap, and a new one asked for at once when the
    # chat moved on (it prints when it arrives, BetweenTurns#flush_recap).
    def handle_recap_command
      recap = @engine.recap
      return recap_command_text(enabled: false) unless recap

      saved = @engine.saved_recap
      request = @engine.turn_running? ? :busy : @engine.request_recap
      recap_command_text(enabled: true, saved: saved, request: request, min_user_turns: recap.min_user_turns)
    end

    # A resumed session doesn't get the default input either.
    def default_input_wanted? = !@resume_session && !@no_default_input

    def clone_messages(messages)
      Array(messages).map(&:dup)
    end

    # While a turn runs, a line submitted at the open prompt steers it: it
    # merges at the next iteration boundary (Kernel), and one that comes after
    # the last runs as the next turn. Reminder turns too.
    def with_steering(&block)
      return yield unless @repl_input

      @repl_input.during_turn(method(:steer_line), leftovers: -> { @pending_input_queue.drain }, &block)
    end

    # On the reader thread, from ReplInput: takes a line for the running turn.
    # A line sent after Ctrl-C waits for the next turn (the kernel would not
    # merge it into the cancelled one). Ctrl-D or exit ends the REPL after
    # the turn. /stats and /recap run now, an anytime command (/help, a
    # plugin's /btw) starts now on its own thread; other commands wait, back
    # in the prompt.
    # @return [Boolean, :back] whether the turn took it, :back to put it back
    def steer_line(line)
      local = local_command(line) unless line.nil?
      return exit_after_turn(delete: SessionCommands.delete_on_exit?(line)) if line.nil? || local == :exit
      return detach_note if local == :detach
      return false if @active_cancel_controller&.cancelled?
      return start_anytime_command(line) if command_registry.lookup(line)&.anytime
      # A command, never steering text (/archive waits, back in the prompt).
      return command_during_turn(line) if local || command_registry.command?(line)
      return true if line.strip.empty?
      # Steering merges text only: a line with images runs as the next turn.
      return image_line_waits if ImageInput.extract(line).any?

      @pending_input_queue.push(line.strip)
      true
    end

    def image_line_waits
      @surface.commit(IMAGE_LINE_WAITS)
      false
    end

    def detach_note
      @surface.commit(REPL_DETACH_NOTE)
      true
    end

    def exit_after_turn(delete: false)
      @exit_after_turn = true
      @delete_on_exit = true if delete
      @surface.commit(delete ? "(exits after this turn and deletes the session; Ctrl-C cancels the turn)" : "(exits after this turn; Ctrl-C cancels it)")
      true
    end

    # A line already queued (none waits for input), or nil.
    def queued_line
      kind, line = @repl_input&.pop(timeout: 0)
      kind == :line ? line : nil
    end

    # @return [true, :back]
    def command_during_turn(line)
      return true if show_local_command(line)

      @surface.commit(COMMAND_BUSY)
      :back
    end

    # D8: an anytime command runs on its own thread while the turn goes on
    # (it reads copies, and shows things through its ctx). What it prints
    # while the turn runs goes above the live region now, its cards as it
    # shows them (BetweenTurns#observe); once the turn has ended it waits for
    # the prompt's flush.
    # @return [true]
    def start_anytime_command(line)
      @engine.spawn_anytime do
        output = @engine.running_anytime { @commands.run(line) }&.output
        @between_turns.show_or_keep({ type: :command_output, text: "\nmodel> #{output}" }) unless output.nil?
      rescue StandardError => e
        @between_turns.keep({ type: :command_output, text: "\nmodel> #{line.split.first}: #{e.message}" })
      end
      true
    end

    # The kernel's drain at an iteration boundary: queued lines, sent as
    # typed and saved in the history.
    def drain_steering
      @pending_input_queue.drain.map do |line|
        persist_recent_history(line)
        line
      end
    end

    # The REPL's on_event sink for Engine#run_turn: render one event, after
    # taking what the status row shows from it (as AttachedLoop does from the
    # Bridge's). Engine swallows on_event errors to protect the turn, so log
    # ours instead.
    def handle_stream_event(event)
      @status_row.take_event(event)
      @renderer.call(event)
    rescue StandardError => e
      Log.error(:repl, "render_failed", echo: "[render] #{event[:type]}: #{e.class}: #{e.message}", event_type: event[:type].to_s, error: e.class.name)
    end

    def cancelled_result_from(messages, reason:)
      KernelLoop::Result.new(
        output: "",
        conversation: clone_messages(messages),
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: [],
        canceled: true,
        cancellation_reason: reason
      )
    end

    # The status row under the prompt, from the Engine's state (what a
    # worker hands an attached TUI when it joins): drawn when it changed.
    def refresh_status_row
      state = @engine.session_state_snapshot.merge(model_name: @effective_model_name)
      @status_row.take_state(state, default_model: @default_model_name)
    end

    # Resolve the recap config (on by default). Returns false when explicitly
    # disabled, nil when nothing is configured, or a Hash when enabled so the
    # Engine can build the detector. Single precedence path via the Config
    # registry: CLI > ENV (SAMAGOTCHI_RECAP_*) > file (recap:) > default.
    def recap_config
      ConfigFile.recap_config
    end


    # Reset the Engine's shared inactivity clock when a prompt opens (a
    # Reline.pre_input_hook) and on each key typed (RelineSeam.key_handler). This is the
    # single seam the Engine-owned idle recap detector reads, so the idle clock
    # is identical for the REPL and any other Engine-backed UI. Chains onto any
    # previously-installed hook (e.g. the input prefill hook).
    def with_activity_hook
      previous_hook = Reline.pre_input_hook
      previous_key_handler = RelineSeam.key_handler
      Reline.pre_input_hook = proc do
        @engine.record_activity
        previous_hook.call if previous_hook
      end
      # Typing is activity too: a reminder waits while you type.
      RelineSeam.key_handler = -> { @engine.record_activity }
      yield
    ensure
      Reline.pre_input_hook = previous_hook
      RelineSeam.key_handler = previous_key_handler
    end

    # ── Ask-user-question adapter (generic TUI renderer) ─────────────────────

    # Non-blocking observer: the turn thread emits :question_requested; we stash
    # it so the REPL thread (the only one that may touch Reline) can drain it
    # at the top of run_assist_loop without racing the completion.
    def handle_question_event(event)
      return unless event.is_a?(Hash)

      type = event[:type] || event["type"]
      return unless type.to_s == "question_requested"

      pq = event[:pending_question] || event["pending_question"]
      return unless pq

      @pending_question_event = pq
    rescue StandardError
      nil
    end

    # Called from REPL thread (run_assist_loop top) — renders widget, blocks
    # until user selects, then answers via Engine#answer_question which wakes
    # the parked turn thread.
    def drain_pending_question?
      pq = @pending_question_event
      # Also check Engine's persisted pending (covers resume)
      pq ||= @engine.pending_question
      return false unless pq

      # If the pending no longer matches the engine's current pending (stale
      # event after sync handler already answered and cleared), discard.
      current = @engine.pending_question
      if current && (pq[:id] || pq["id"]).to_s != (current[:id] || current["id"]).to_s
        @pending_question_event = nil
        return false
      end
      if current.nil? && @pending_question_event
        # Stale stash where engine already cleared (sync path completed)
        @pending_question_event = nil
        return false
      end

      @pending_question_event = nil
      result = render_question_widget(pq)
      return false unless result

      # result is already answered via Engine#answer_question in render_question_widget
      true
    rescue StandardError => e
      Log.warn(:repl, "question_drain_failed", echo: "[ask_user_question] drain failed: #{e.class}: #{e.message}", error: e.class.name)
      false
    end

    # The choices wait in the notes slot, laid out for the rows it gets, and
    # the answer is a line at the ? prompt. Once the question closes, one
    # line (the question and what became of it) stays in the scrollback.
    def render_question_widget(pending)
      prompt = QuestionPrompt.new(pending)

      # The activity row goes while the question waits.
      @view.finish_thinking_spinner
      # An edit's diff goes above the slot, into the scrollback.
      preview = prompt.preview_lines(paint: method(:paint))
      @surface.commit(preview.join("\n")) unless preview.empty?
      choices = prompt.slot(paint: method(:paint))

      question_prompt = paint(QUESTION_PROMPT, 33)
      unless @repl_input
        @surface.set_slot(:notes, choices)
        return answer_question_widget(prompt) { read_choice_line(question_prompt) }
      end

      # On a terminal the prompt is open (a turn runs with it): it turns into
      # the ? prompt for the answer. Only a line submitted there answers,
      # never one typed before the question came. The choices show once the
      # typed text is out of the prompt.
      @repl_input.ask(question_prompt) do |answers|
        @surface.set_slot(:notes, choices)
        answer_question_widget(prompt) { take_open_prompt_answer(answers) }
      end
    ensure
      @surface.clear_slot(:notes)
    end

    # Loop until a valid selection or a cancel. The block reads one answer:
    # a line, nil (Ctrl-D, or Ctrl-C with no turn), or :canceled (the turn
    # was cancelled).
    def answer_question_widget(prompt)
      loop do
        raw = begin
          yield
        rescue Interrupt
          nil
        end
        raw = raw.to_s.strip unless raw.nil? || raw == :canceled
        if raw.nil? || raw == :canceled || raw.empty?
          # Empty, EOF / Ctrl-D / Ctrl-C -> cancel (an approval: denied)
          @engine.cancel_question("user") rescue nil
          outcome = if raw == :canceled then "(turn cancelled)"
                    elsif prompt.approval? then "(denied)"
                    else "(cancelled)"
                    end
          close_question_widget(prompt, outcome)
          return false
        end

        answer = prompt.parse(raw)
        @surface.commit(answer.note) if answer.note
        unless answer.ok?
          # The read left no echo: the line shows above its error.
          @surface.commit("#{paint(QUESTION_PROMPT, 33)}#{raw}")
          @surface.commit(answer.error)
          next
        end

        begin
          @engine.answer_question(id: prompt.id, selected: answer.selected, freeform: answer.freeform)
          close_question_widget(prompt, prompt.answer_text(answer))
          return true
        rescue ArgumentError => e
          @surface.commit("Invalid: #{e.message}. Try again.")
          next
        rescue StandardError => e
          close_question_widget(prompt, "(error: #{e.message})")
          return false
        end
      end
    end

    def close_question_widget(prompt, outcome)
      @surface.clear_slot(:notes)
      @surface.commit(prompt.summary(outcome, paint: method(:paint)))
    end

    # A ? read of its own, off a terminal (specs, pipes): $stdin.gets.
    def read_choice_line(question_prompt)
      @surface.set_slot(:editor, [question_prompt])
      $stdin.gets
    end

    # The next line submitted at the open prompt (?), nil for Ctrl-D
    # or a Ctrl-C with no turn running, or :canceled when Ctrl-C cancels the
    # running turn first (the read goes on; the question closes).
    def take_open_prompt_answer(answers)
      controller = @active_cancel_controller
      loop do
        kind, line = answers.pop(timeout: REMINDER_PENDING_POLL_INTERVAL)
        return kind == :line ? line : nil if kind
        return :canceled if controller&.cancelled?
      end
    end
  end
end
