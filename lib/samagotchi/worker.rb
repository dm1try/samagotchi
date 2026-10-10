# frozen_string_literal: true

require "fileutils"

require_relative "client_id"
require_relative "config"
require_relative "events"
require_relative "session"
require_relative "session_inbox"
require_relative "turn_note"
require_relative "steer"
require_relative "worker_idle_exit"
require_relative "worker_wakes"
require_relative "worker_inbound"
require_relative "session_manager"
require_relative "archive_store"
require_relative "log"
require_relative "turn_flow"
require_relative "llm/errors"
require_relative "continue_offer"
require_relative "iteration_limit"
require_relative "session_commands"
require_relative "queued_command"
require_relative "model_profile"
require_relative "child_reports"
require_relative "child_move"
require_relative "context_absorber"
require_relative "context_poller"
require_relative "tools/task_runtime"

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
    # A worker just started runs no wake turn for delegate reports this
    # long: a worker spawned for a message (chi send to a stopped parent)
    # gets it over the Bridge a moment after it starts, and that message's
    # turn goes first (the reports join it).
    WAKE_START_GRACE = 2.0
    # How much of a command's output goes into its :command_ran.
    COMMAND_OUTPUT_LIMIT = 4096
    BUSY_OUTPUT = "busy: wait for the turn to end"
    # !rollback mid-turn would mean "the turn I'm in".
    ROLLBACK_BUSY_OUTPUT = "busy: Ctrl-C the turn first, then !rollback"

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
      # The exit asked for is a restart (POST /exit restart: true).
      @exit_restart = false
      # The lines the running turn's drain merged ([prompt, origin]), for a
      # failed prompt turn to hand back; reset as each turn begins.
      @merged_this_turn = []
      # A delegate child's side (ChildRing): whether the running turn is
      # its parent's (it rings when it ends), whether that turn rang a
      # question, and whether the next turn rings whatever its origin (it
      # follows a question the parent was rung about: D10).
      @reporting_turn = false
      @asked_parent = false
      @owes_parent = false
      @initial_turn = false
    end

    # Whether the session was empty as the worker left it, so the caller
    # deletes it once the lock is free (SessionManager.run_session_loop
    # checks again then).
    def discard? = @discard

    # Whether delegate reports wait that an idle parent runs a turn for
    # (#wake_state): SessionManager.run_session_loop starts a new worker
    # for them after this one leaves. Reports the budget or a failure held
    # back wait for the next human input instead.
    def wake_due? = wake_state == :due

    # What a new session starts on (and /model resets to); nil before #run.
    attr_reader :default_model

    # @return [Symbol] :idle_exit, :exit_requested when a client asked it
    #   to exit (Bridge POST /exit), :restart when it asked for a restart
    #   (the caller starts a new worker), :stopped when the session was stopped
    #   (chi stop), :crashed when the loop raised (the session is marked
    #   errored); SessionManager.run_session_loop turns it into the exit
    def run
      start
      serve
      begin
        # A session stopped before this worker took the lock (e.g. a stop
        # right after create) must not run its initial prompt.
        return :stopped if stopped_on_disk?

        start_background
        loop do
          leaving = pass
          return leaving if leaving
        end
      rescue StandardError => e
        crashed(e)
      ensure
        teardown
      end
    end

    private

    # The session, its Engine and what runs its turns, before anyone can
    # reach it.
    def start
      # The wake turns' budget (delegate reports, attached context), from now.
      @wakes = WorkerWakes.new(grace: WAKE_START_GRACE)
      # This worker holds the session now (a continue's starting marker held
      # off any other until it did), and a continue that died moving
      # delegates here left its intent: finish it.
      ChildMove.clear_starting(@session_id, state_dir: @state_dir)
      ChildMove.adopt(@session_id, state_dir: @state_dir)
      @session = Session.load(@session_id, state_dir: @state_dir)
      drop_dead_question
      @engine = build_engine
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      @engine.session = @session
      # Input already waiting in the inbox starts the next turn at once: no
      # turn-end warm-up then.
      @engine.next_turn_waiting = -> { SessionInbox.find_new_input_files(@session_dir).any? || wake_due? }
      @turn_flow = TurnFlow.new(engine: @engine)
      # Its question's answer is queued as the matching /continue (the
      # Bridge exists by the time anyone answers).
      @continue_offer = ContinueOffer.new(engine: @engine, turn_flow: @turn_flow, run_turn: method(:run_engine_turn),
                                          max_iterations: method(:max_iterations),
                                          queue_command: lambda { |line, client_id:|
                                            @bridge.queue_command(line, client_id: client_id, card: true)
                                          })
      # A recap written while a continue offer waits says the turn stopped
      # unfinished (before the idle jobs start).
      @engine.recap&.awaiting_continue = -> { @turn_flow.awaiting_continue? }
      # The seq of the last turn's end event: a command queued before it was
      # queued while that turn ran.
      @turn_end_seq = 0
      @engine.subscribe(observer: lambda { |event|
        if Events::TURN_END.include?(event[:type])
          @turn_end_seq = event[:event_seq]
          @turn_end_type = event[:type]
        end
        @turn_id = event[:turn_id] if event[:type] == :turn_started
        ring_question(event) if event[:type] == :question_requested
      })
      # This session's own delegate children's news (rings in children/).
      @child_reports = ChildReports.new(session_id: @session_id, state_dir: @state_dir,
                                        predecessor: @session.continues)
      # Its attached context's notes (ContextSources).
      @context_absorber = ContextAbsorber.new(session_id: @session_id, state_dir: @state_dir,
                                              project_root: @session.project_root)
      # What comes in between turns, and how each kind is saved.
      @inbound = WorkerInbound.new(session: @session, state_dir: @state_dir, session_dir: @session_dir, engine: @engine,
                                   context_absorber: @context_absorber, wakes: @wakes,
                                   awaiting_continue: -> { @turn_flow.awaiting_continue? },
                                   stopped: -> { stopped_on_disk? },
                                   queue_command: lambda { |line, client_id, after_file|
                                     @bridge.queue_command(line, client_id: client_id, after_file: after_file)
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
    end

    # The Bridge (UIs and clients reach the worker from here on), then the
    # idle-exit policy.
    def serve
      @bridge = SessionManager.start_bridge(engine: @engine, state_dir: @state_dir, session_id: @session_id,
                                            on_input: -> { @waker.wake },
                                            on_command: method(:on_command),
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
        awaiting_continue: -> { @turn_flow.awaiting_continue? },
        running_tasks: -> { Tools::TaskRuntime.running_created_in(@engine.messages_checkpoint) }
      )
    end

    # What runs beside the loop until it leaves.
    def start_background
      # Plugins' slow setup (chi.init: an MCP server's first start), in
      # the background, shown by the UIs; a turn waits only for the ones
      # that bring tools.
      @engine.start_init_tasks!
      # Attached context's commands, in the background; a new text wakes
      # the loop to absorb it. Not activity: the idle exit stops it.
      @context_poller = ContextPoller.new(session_id: @session_id, state_dir: @state_dir,
                                          project_root: @session.project_root, cwd: @session.working_directory,
                                          on_change: -> { @waker.wake }).start
    end

    # One pass of the loop: the first work found runs (queued commands, a
    # context wake turn, the first prompt, the queued input files) and the
    # next pass looks again; with none, #idle_pass.
    # @return [Symbol, nil] what #run returns as the worker leaves, nil to go on
    def pass
      # Check if the session was externally marked as stopped. Not
      # stopped_on_disk?, which reads a vanished file as "not stopped":
      # a session file deleted under a running worker crashes it here
      # instead of being saved back by its next turn.
      return :stopped if Session.load(@session_id, state_dir: @state_dir).status == Session::STATUS_STOPPED

      # Commands queued before a prompt run first (a /continue sent
      # before a new prompt still answers the offer).
      return if run_queued_commands

      # Between turns, so the next turn (the first one too) sees them.
      # A change that asks to wake may start a turn here (C4), but not
      # ahead of an exit or restart a client asked for: it is a note then.
      @inbound.absorb_notes
      return if absorb_context(wake: nothing_queued? && !@exit_requested)

      if (prompt = @inbound.take_initial_prompt)
        run_initial_prompt(prompt) unless @inbound.initial_command?(prompt)
        return
      end

      input_files = SessionInbox.find_new_input_files(@session_dir)
      return idle_pass if input_files.empty?
      # A command queued since the look above, before these prompts were
      # written (an answer's /continue yes, then a prompt), still runs
      # first; the next pass takes the prompts.
      return if run_queued_commands

      run_input_files(input_files)
    end

    # Nothing queued: a delegate wake turn or a due reminder runs, else
    # the worker leaves when the idle exit or a client's exit is due, else
    # it sleeps until woken or the fallback tick.
    # @return [Symbol, nil] as #pass
    def idle_pass
      return if run_wake_turn
      return if run_due_reminders
      return left(:idle_exit) if @idle_exit.due? && leave_idle
      return left(@exit_restart ? :restart : :exit_requested) if @exit_requested && leave_on_request

      @waker.wait(idle_wait)
      nil
    end

    # @return [nil]
    def run_input_files(input_files)
      input_files.sort.each do |input_file|
        # A stop between two queued turns leaves the rest queued.
        break if stopped_on_disk?

        # Commands that came before this file (D1: a queued /model X sent
        # before this prompt, a command an earlier file carried) run first.
        run_queued_commands
        @inbound.absorb_notes
        run_input_file(input_file)
      end
      nil
    end

    # An error outside a turn: the session is marked errored.
    # @return [Symbol] :crashed
    def crashed(error)
      # Its stderr is /dev/null: the log is the only trace of why.
      Log.exception(:worker, "crashed", error)
      Session.mark_error(@session_id, reason: error.message, state_dir: @state_dir)
      # A delegate's parent hears of it (best effort).
      ChildRing.ring(@session, why: "crash", state_dir: @state_dir) if @session
      :crashed
    end

    # The anytime commands finish and the plugins' services stop (a
    # server process), whatever the way out; the Bridge last, so a
    # command's command_ran still reaches its UI on a crash. A
    # step-limit question stays in the file (a save here would write
    # over a stop's status): with no live worker the lists don't read
    # it as waiting, and the next worker drops it (drop_dead_question).
    # The context poller first: a command it runs goes (its process
    # group) before the Engine does.
    def teardown
      @context_poller&.stop
      drop_queued_commands
      @engine&.shutdown
      @bridge&.stop
      # The process exits next: a parent wake it rang for (a crash's
      # ring comes just above) must spawn the parent's worker first.
      ChildRing.await_wakes
    end

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
      save_or_log(:dead_question) { @session.save(state_dir: @state_dir) }
    end

    # The attached context's notes (WorkerInbound#absorb_context), and the
    # context wake turn one may start. A failure to read or write them (or
    # in that turn) is logged: the next pass tries again.
    # @return [Boolean] whether a wake turn ran
    def absorb_context(before_turn: false, wake: false)
      context_wake = @inbound.absorb_context(before_turn: before_turn, wake: wake)
      return false unless context_wake

      run_context_wake_turn(context_wake)
      true
    rescue SystemCallError, IOError => e
      Log.exception(:worker, "context_failed", e)
      false
    end

    # No input file or queued command waits: the loop would go idle.
    def nothing_queued? = @command_queue.empty? && SessionInbox.find_new_input_files(@session_dir).empty?

    # A turn nobody typed for a changed source (a context wake): a continue
    # turn from context:<name> whose first message is the wake note already
    # in the conversation (named by +turn_id+), on the same rules as a
    # delegate report's wake turn: it counts toward session.max_wakes, and
    # a failure goes back to before the turn (the note stays, as a plain
    # one: WorkerInbound#unmark_wake) and pauses wakes until a human's input.
    # +context_wake+: a WorkerInbound::ContextWake.
    def run_context_wake_turn(context_wake)
      name = context_wake.name
      Log.info(:worker, "context_wake_turn", name: name, in_a_row: @wakes.count!)
      @turn_flow.before_prompt_turn
      run_engine_turn(nil, continue: true, origin: context_wake.origin,
                           id: context_wake.turn_id, max_iterations: IterationLimit.for) do |result, error|
        if error
          kept = @turn_flow.prompt_turn_failed(error: error, wake: "the change in attached context #{name}") == :kept
          # A turn that got somewhere stays, its wake mark with it.
          @inbound.unmark_wake(context_wake) unless kept
          @wakes.pause!
        else
          @continue_offer.after_turn(result)
        end
      end
    end

    # The first prompt (spawn_session's): a delegate child's task, which is
    # its parent's although no client sent it.
    def run_initial_prompt(prompt)
      @initial_turn = true
      run_prompt(WorkerInbound::Prompt.new(text: prompt))
    ensure
      @initial_turn = false
    end

    def run_input_file(input_file)
      @inbound.take_input(input_file) { |prompt| run_prompt(prompt) }
    end

    # @param prompt [WorkerInbound::Prompt]
    def run_prompt(prompt)
      origin = prompt.origin
      # A first turn sees the context attached before it.
      absorb_context(before_turn: true)
      user_input(origin&.dig(:client_id))
      @continue_offer.drop(origin)
      @turn_flow.before_prompt_turn
      run_engine_turn(prompt.text, origin: origin, max_iterations: max_iterations(prompt.no_interrupt),
                                   images: prompt.images) do |result, error|
        if error
          # The Engine announced :turn_failed (with the error's one line).
          restore_failed_turn([[prompt.text, origin, prompt.images], *@merged_this_turn], error: error)
        else
          @continue_offer.after_turn(result, no_interrupt: prompt.no_interrupt)
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

      @continue_offer.drop({ client_id: ClientId::REMINDER })
      # A failure has no prompt to hand back (the Engine announced
      # :turn_failed). The offer went before the turn
      # (ContinueOffer#drop); either way the rollback window closes.
      run_engine_turn(nil, continue: true, origin: { client_id: ClientId::REMINDER },
                           max_iterations: IterationLimit.for) { @turn_flow.after_reminder_turn }
      true
    end

    # :due when an idle parent should run a turn for its delegate
    # children's reports now (session.delegate_reports: wake): rings wait,
    # no continue offer does (they merge into its turn), wakes aren't paused
    # by a failed one, and the wake budget isn't spent; :budget when only
    # the budget stops it; nil otherwise.
    def wake_state
      return nil unless @child_reports && ChildRing.mode == "wake"

      @wakes.delegate_state(awaiting_continue: @turn_flow&.awaiting_continue?) { @child_reports.waiting? }
    end

    # Run a turn nobody typed for the reports the rings bring (a wake turn):
    # a continue turn (no prompt bubble) whose first boundary merges them,
    # with origin child:<id8>. A failure goes back to the checkpoint, keeps
    # the rings and pauses wakes until a human's input (a provider outage
    # doesn't loop).
    # @return [Boolean] whether a wake turn ran
    def run_wake_turn
      return false if @wakes.in_grace?

      state = wake_state
      budget_notice if state == :budget
      return false unless state == :due

      reports, = take_child_reports
      # The turn must not generate with nothing to say: the drain gets this
      # exact list at its first boundary.
      return false if reports.empty?

      @wakes.hand_over(reports)
      Log.info(:worker, "delegate_wake_turn", reports: reports.size, in_a_row: @wakes.count!)
      @turn_flow.before_prompt_turn
      restores = @turn_flow.restores
      run_engine_turn(nil, continue: true, origin: reports.first.origin, max_iterations: IterationLimit.for) do |result, error|
        if error
          # Rolled back, the rings stay (settle_child_reports): the user's
          # next turn takes them. A turn that got somewhere stays, and read them.
          @turn_flow.prompt_turn_failed(
            error: error, wake: reports.size == 1 ? "a delegate's report" : "#{reports.size} delegate reports",
            wake_kept: "chi keeps #{reports.size == 1 ? "the report and brings it" : "the reports and brings them"} " \
                       "again with the user's next message."
          )
          @wakes.pause!
        else
          @continue_offer.after_turn(result)
          # Stopped before it got anywhere (a Stop or a before_turn hook's
          # cancel before the model call) and restored: its rings stay, and
          # wait for the user's next message as after a failure, rather
          # than waking again at once.
          @wakes.pause! if result.canceled? && @turn_flow.restores != restores
        end
      end
      true
    ensure
      @wakes.drop_handed
    end

    # The idle loop's sleep: the fallback tick, or less while reports wait
    # out the start grace.
    def idle_wait = @wakes.idle_wait(@poll_interval) { wake_state == :due }

    # The wake budget is spent: the parent's UIs hear once that reports
    # wait for the next message.
    def budget_notice
      return unless @wakes.notice_budget!

      count = SessionInbox.find_ring_files(@session_dir).map { |f| SessionInbox.read_ring(f)&.dig(:child_id) }.uniq.size
      @engine.announce(type: :hook_notice, hook: "delegate", level: :info, between_turns: true,
                       text: "#{count} delegate report#{"s" if count != 1} waiting; #{count == 1 ? "it joins" : "they join"} " \
                             "your next message (#{@wakes.max} turn#{"s" if @wakes.max != 1} ran for reports in a row, #{ChildRing::MAX_WAKES_KEY})")
    end

    def max_iterations(no_interrupt) = IterationLimit.for(no_interrupt: no_interrupt)

    # The queued commands that may run now, in order, up to one whose
    # after_file (D1) still waits in the inbox: it and those behind it stay
    # queued.
    # @return [Boolean] whether any command ran
    def run_queued_commands
      ran = false
      while (command = next_ready_command)
        run_command(command)
        ran = true
      end
      ran
    end

    # Pops the first queued command if it may run now (its after_file is
    # taken), else none: one behind it waits too, in arrival order (an idle
    # /model Y that came just after the turn ended stays behind a /model X
    # still waiting for a prompt sent before it). With the event log held,
    # as the Bridge queues.
    def next_ready_command
      return nil if @command_queue.empty?

      @engine.synchronize_events do
        commands = drain_commands
        first = commands.first
        ready = first && ready_command?(first) ? commands.shift : nil
        commands.each { |command| @command_queue << command }
        ready
      end
    end

    def ready_command?(command)
      return true if command.after_file.nil?

      SessionInbox.find_new_input_files(@session_dir).none? { |path| File.basename(path) <= command.after_file }
    end

    def drain_commands
      commands = []
      while (command = next_command)
        commands << command
      end
      commands
    end

    # A command a turn refuses (:refuse while it ran, S1) is answered busy:
    # at the turn's iteration boundaries (mid_turn: all of them), and when
    # it ends (the ones queued before its end event; later ones run next).
    # A queued one (:queue) stays for after the turn, but a !cmd after a
    # canceled or failed turn (D4): running it would close the rollback
    # window the turn left, so it is dropped. With the event log held, so
    # a command the Bridge queues meanwhile stays behind the ones kept, in
    # arrival order. One that comes after the empty look is the next
    # boundary's (or end's), as it would be.
    def refuse_queued_commands(mid_turn: false)
      return if @command_queue.empty?

      @engine.synchronize_events do
        drain_commands.each do |command|
          during = mid_turn || command.after_seq.to_i < @turn_end_seq
          case (during ? turn_answer(command, ended: !mid_turn) : :keep)
          when :refuse then announce_command(command, status: "busy", output: busy_output(command), changed: [])
          when :drop then drop_command(waiting_for_turn_end(command), "turn #{@turn_end_type == :turn_failed ? "failed" : "canceled"}: " \
                                                                      "#{command.line} not run; send it again")
          else @command_queue << (during ? waiting_for_turn_end(command) : command)
          end
        end
      end
    end

    # What a turn does with +command+, queued while it ran: :refuse, :drop
    # (D4, once it +ended+) or :keep. One queued idle just as the turn
    # began (:loop) goes by its line's policy (a show form waits too).
    def turn_answer(command, ended:)
      policy = command.mid_turn
      policy = @engine.command_registry.mid_turn(command.line) if policy == :loop
      return :refuse if policy == :refuse
      return :drop if ended && policy == :queue && shell_command?(command) &&
                      %i[turn_canceled turn_failed].include?(@turn_end_type)

      :keep
    end

    # +command+, kept for after the turn. One queued idle just as the turn
    # began (:loop) whose line waits for a turn's end (/model X, !cmd) is
    # marked as one queued mid-turn: its command_queued (waits) tells the
    # UIs now, and its command_ran says queued.
    def waiting_for_turn_end(command)
      return command unless command.mid_turn == :loop && @engine.command_registry.mid_turn(command.line) == :queue

      @engine.announce(type: :command_queued, **command.event_fields, waits: "turn_end")
      command.with(mid_turn: :queue)
    end

    def shell_command?(command) = @engine.command_registry.lookup(command.line)&.id == :shell

    def busy_output(command)
      @engine.command_registry.lookup(command.line)&.id == :rollback ? ROLLBACK_BUSY_OUTPUT : BUSY_OUTPUT
    end

    # +command+ won't run: its sender (a UI's queued bubble) is told.
    def drop_command(command, output)
      announce_command(command, status: "dropped", output: output, changed: [])
    end

    # The worker leaves with commands still queued (a stop, a crash): each
    # one's sender is told it won't run, so no UI shows it waiting for good.
    def drop_queued_commands
      return if @command_queue.nil? || @command_queue.empty? || @engine.nil?

      @engine.synchronize_events do
        drain_commands.each { |command| drop_command(command, "dropped: the session's worker stopped before it ran") }
      end
    rescue StandardError => e
      Log.warn(:worker, "drop_commands_failed", error: e.class.name, msg: e.message)
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
      save_or_log(:command) { save_session } unless Array(result.changed).empty?
      user_input(command.client_id) if resolved
      @continue_offer.after_command(result, resolved: resolved)
      @continue_offer.run_continue_turn(command) if result.resume
    end

    # @return [Array(SessionCommands::Result, Array<Hash>)] the result, and
    #   the cards and notices it showed, held: they follow its command_ran,
    #   as its output
    def run_command_line(command)
      @engine.holding_announcements { command_result(command) { @commands.run(command.line) } }
    end

    # The block's Result for +command+; one that raised, or found no
    # command for the line, is an error Result saying so.
    # @return [SessionCommands::Result]
    def command_result(command)
      yield || SessionCommands::Result.new(status: :error, output: "not a session command", changed: [])
    rescue StandardError => e
      SessionCommands::Result.new(status: :error, output: "#{command.line.split.first}: #{e.message}", changed: [])
    end

    # A session command from the Bridge, called with the event log held:
    # an anytime one starts now, any other is queued for the loop (and
    # refused if a turn runs: #refuse_queued_commands). While a turn runs
    # the line's policy decides (a show form like /model runs now); idle,
    # only an always-anytime command (/help) runs beside the loop, so an
    # idle /model X then /model run in order. A turn starting or ending
    # right now may see the other side: the line is only shown early or
    # run in order.
    #
    # A queued one (:queue) keeps arrival order with the prompts (D1): it
    # runs once every input file written before it is taken (after_file,
    # the newest one now; names compare, not clocks), so a prompt sent
    # before it runs first and one sent after it runs after. One that came
    # in an input file runs once that file is taken (+after_file+).
    # @return [Symbol] the policy it applied (the Bridge marks an anytime
    #   one's command_queued, and a queued one's): :anytime, :queue or
    #   :refuse while a turn runs, :loop idle
    def on_command(command, after_file: nil)
      registry = @engine.command_registry
      policy = if @engine.turn_running? then registry.mid_turn(command.line)
               else registry.anytime?(command.line) ? :anytime : :loop
               end
      if policy == :anytime
        start_anytime_command(command)
        return policy
      end

      after_file ||= newest_input_file if policy == :queue
      # The count says which turn ends came before it.
      @command_queue << command.with(after_seq: @engine.event_count, mid_turn: policy, after_file: after_file)
      @waker.wake
      policy
    end

    # @return [String, nil] the newest input file waiting (its basename)
    def newest_input_file
      SessionInbox.find_new_input_files(@session_dir).map { |path| File.basename(path) }.max
    end

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
        result = command_result(command) { @engine.running_anytime { @commands.run(command.line) } }
        announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                  anytime: true)
      rescue StandardError => e
        Log.warn(:worker, "anytime_command_failed", line: command.line, error: e.class.name, msg: e.message)
      end
    end

    # @param anytime [Boolean] an anytime command's: its line was shown at
    #   its command_queued already
    def announce_command(command, status:, output:, changed:, anytime: false)
      text = output.to_s
      event = { type: :command_ran, **command.event_fields, status: status, output: text[0, COMMAND_OUTPUT_LIMIT],
                changed: changed.map(&:to_s), model_name: @engine.effective_model_name }
      event[:anytime] = true if anytime
      # Its line was shown at its command_queued (waits: turn_end).
      event[:queued] = true if command.waits_for_turn_end?
      # /llm-context or /model: what the next turn runs under now (the web's chip).
      event[:llm_context] = @engine.llm_context_summary if changed.intersect?(%i[llm_context model])
      event[:output_truncated] = true if text.length > COMMAND_OUTPUT_LIMIT
      @engine.announce(event)
    end

    # One Engine turn, the same for a prompt, a reminder and a continue:
    # the session shows as running to readers of the file (the web's
    # session list; the Engine resets it to idle when it ends), commands
    # queued while it ran are refused, then the caller's block takes the
    # result (or the error the Engine announced as :turn_failed), the
    # answer goes to the output file and the session is saved.
    # A failure before the Engine's turn began (this save, say) goes to the
    # block too, with no :turn_failed: it is logged, the session idle again.
    # @yieldparam result [Object, nil] Engine#run_turn's, nil on a failure
    # @yieldparam error [StandardError, nil]
    def run_engine_turn(prompt, **turn_args)
      # Every kind of turn merges steering (a reminder turn too, which may be
      # a fresh worker's first), so the list is this turn's from the start.
      @merged_this_turn = []
      @reporting_turn = reports_to_parent?(turn_args[:origin])
      restores = @turn_flow.restores
      begin
        @session.status = Session::STATUS_RUNNING
        # A continue that moved this session to the chain's new link wrote
        # the new parent beside it (Session::PARENT_FILE): this turn's
        # status, its rings and every save from here on say so.
        @session.parent_id = Session.parent_override(@session_id, state_dir: @state_dir) || @session.parent_id
        @session.save(state_dir: @state_dir)
        result = @engine.run_turn(@session, prompt, pending_input: pending_input_drain, **turn_args)
      rescue StandardError => e
        error = e
        # Still running: no turn of the Engine's ended (it never began).
        # It ends here, failed, as an Engine turn would record it: a wait
        # (ReplyWait) tells a turn's end by last_turn.
        if @session.status == Session::STATUS_RUNNING
          @session.status = Session::STATUS_IDLE
          @engine.record_last_turn(@session, "failed", 0, turn_args[:origin], { type: :turn_failed })
          Log.warn(:worker, "turn_not_begun", error: e.class.name, msg: e.message)
        end
      ensure
        refuse_queued_commands
      end
      yield result, error
      response = result&.output
      # A turn that ran out of iterations and asks whether to continue left
      # no reply: its text is what came before its last tool calls, and a
      # wait (chi send --wait) gets the question instead.
      unless response.nil? || response.strip.empty? || @continue_offer.awaiting?
        SessionInbox.write_output(@session_dir, response)
      end
      save_or_log(:turn) { save_session }
      # The reports the turn merged were read unless its end took the turn
      # back out of the conversation (TurnFlow restored a checkpoint: a
      # failed prompt or wake turn that got nowhere, a canceled continue
      # turn). A failed turn whose work stayed, and a reminder or continue
      # turn that failed (kept with its failed note), read them.
      settle_child_reports(rolled_back: @turn_flow.restores != restores || merges_lost?(error))
      ring_parent_after_turn
    end

    # The delegate reports this turn took: a kept turn moves the cursors on
    # and deletes their rings; a rolled-back one leaves the rings for the
    # next turn. Once either way: the model reads a report in the
    # conversation, or the next turn brings it (unless a later !rollback
    # erases a kept turn, which drops what it read).
    def settle_child_reports(rolled_back:)
      rolled_back ? @child_reports.release : @child_reports.commit
    end

    # Whether +error+ ended the turn without its loop's conversation: a
    # failure the loops didn't mark (LLM::FailedTurn), one past their end
    # (the Engine's own end of the turn, say). The Engine kept the turn's
    # start only, so the reports its loop merged are not in the
    # conversation: their rings stay for the next turn, even when the turn
    # itself stays (a reminder or continue turn). Not one raised after the
    # turn ended (the Engine's post-turn work): the turn was kept as it
    # ended, completed or canceled, the reports in it (a turn TurnFlow
    # takes back is a restore, above).
    def merges_lost?(error)
      return false if error.nil? || error.is_a?(LLM::FailedTurn)

      !KEPT_TURN_OUTCOMES.include?(@session.last_turn&.outcome)
    end

    # The Engine's turn endings that keep the turn's conversation (#merges_lost?).
    KEPT_TURN_OUTCOMES = %w[completed canceled].freeze

    # A delegate child's turn that was its parent's (#reports_to_parent?)
    # rings the parent, after the save: the parent reads a settled child.
    # A question it rang about that still waits makes the next turn ring
    # too, whoever starts it (the user answering Continue on the web).
    def ring_parent_after_turn
      ChildRing.ring(@session, why: "turn_end", state_dir: @state_dir) if @reporting_turn
      @owes_parent = @asked_parent && !@session.pending_question.nil?
      @asked_parent = false
      @reporting_turn = false
    end

    # Whether the turn starting now is a delegate child's parent's: its
    # task (the initial prompt), a follow-up, a continue the parent
    # answered, a reminder, anything but a human typing into the child
    # (ClientId.human?), and any turn after a question the parent
    # was rung about.
    def reports_to_parent?(origin)
      return false unless @session.delegate?

      @initial_turn || @owes_parent || !ClientId.human?(origin&.dig(:client_id))
    end

    # The Engine published a question (after the question desk saved it).
    # In a turn that reports to the parent, the model's own question and
    # the step-limit continue ring it; approvals and hooks' questions are
    # the user's, on this session's card.
    def ring_question(event)
      return unless @reporting_turn

      kind = event.dig(:pending_question, :kind).to_s
      return unless ["", ContinueOffer::KIND].include?(kind)

      ChildRing.ring(@session, why: "question", state_dir: @state_dir)
      @asked_parent = true
    end

    # WorkerInbound.save_or_log: a failed save between turns is logged.
    def save_or_log(at, &) = WorkerInbound.save_or_log(at, &)

    # Back to the conversation before the failed turn, as the REPL does (so
    # failed prompts don't pile up as consecutive user messages), and each
    # prompt it took (its own and any merged into it) goes back to its
    # sender, who can send it again. The rollback and the announcements are
    # one step of the event log: a snapshot shows the failed turn's messages
    # or the restored ones, never the one without the other. A turn that
    # got somewhere stays instead (TurnFlow#prompt_turn_failed), with the
    # prompts it took: nothing goes back.
    # @param prompts [Array<Array(String, Hash|nil, Array|nil)>] [prompt,
    #   origin, images] (a web client gets its image chips back)
    # @param error [Exception, nil] what failed: its one line stays in the
    #   conversation as a turn note
    # Not saved here: run_engine_turn saves after its block.
    def restore_failed_turn(prompts, error: nil)
      @engine.synchronize_events do
        next if @turn_flow.prompt_turn_failed(error: error) == :kept

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
                            .take_while { |input_file| !SessionInbox.waits_for_turn_end?(input_file) }
        merged = files.filter_map do |input_file|
          claimed_file = SessionInbox.claim_input_file(input_file)
          next unless claimed_file

          begin
            input = SessionInbox.read_input(claimed_file)
            prompt = input.prompt.to_s.strip
            prompt.empty? ? nil : [prompt, input.origin]
          ensure
            FileUtils.rm_f(claimed_file)
          end
        end
        merged.each { |_prompt, origin| user_input(origin&.dig(:client_id)) }
        # Delegate children's reports: never handed back on a failure
        # (their rings stay for the next turn), so not in @merged_this_turn.
        reports, mark = take_child_reports
        unless merged.empty? && reports.empty?
          @engine.announce(type: :input_merged, count: merged.size + reports.size,
                           origins: merged.filter_map(&:last) + reports.map(&:origin))
          @merged_this_turn.concat(merged)
        end
        # Each line keeps its sender (Steer.source_for_client): a chi send or
        # a delegating parent's line is saved and shown to the model as theirs.
        lines = merged.map { |prompt, origin| Steer::Line.new(text: prompt, source: Steer.source_for_client(origin&.dig(:client_id))) } +
                reports.map(&:line)
        # A wake turn starts with its first line, whoever sent it.
        lines[0] = lines[0].with(mark: mark) if mark && lines.any?
        lines
      end
    end

    # The reports for rings that came in since the turn last looked. A
    # failure to read them must not take the turn's steering with it.
    # A wake turn's first call gets the reports it was started for (their
    # message is the turn's start: turn_start, turn_id, so a reload shows
    # the turn as its own).
    # @return [Array(Array<ChildReports::Report>, Hash|nil)] the reports
    #   and the mark of their message
    def take_child_reports
      if (reports = @wakes.take_handed)
        return [reports, { turn_start: true, turn_id: @turn_id }.compact]
      end

      [@child_reports.take, nil]
    rescue StandardError => e
      Log.warn(:worker, "delegate_reports_failed", error: e.class.name, msg: e.message)
      [[], nil]
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
    # +restart+: a new worker takes over (on the newest chi installed), so
    # WorkerIdleExit#hold_for_restart's rules, and no recap or discard.
    # @return [Symbol, nil] what keeps the worker up, nil when it will leave
    def exit_request(client_id, delete: false, restart: false)
      # The Bridge serves before the idle-exit policy exists.
      return :starting unless @idle_exit

      hold = restart ? @idle_exit.hold_for_restart : @idle_exit.hold_for_request(requester: client_id)
      return hold if hold

      @exit_requested = true
      @exit_requested_by = client_id
      @exit_deletes = delete && !restart
      @exit_restart = restart
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
        hold = if @exit_restart
                 @idle_exit.hold_for_restart
               else
                 @idle_exit.hold_for_request(requester: @exit_requested_by, streams: false)
               end
        if hold
          @exit_requested = nil
          @exit_restart = false
          Log.info(:worker, "exit_held", reason: hold)
          next false
        end

        @bridge&.stop
        @engine.stop_idle
        Log.info(:worker, @exit_restart ? "restart_requested" : "exit_requested", by: @exit_requested_by || "a client")
        true
      end
    end

    # @return [Symbol] +result+, with #discard? decided and, for a session
    #   kept, its recap written: the Bridge is closed and the idle jobs are
    #   stopped by now, and nothing waits on this (the TUI has detached). A
    #   `chi send` meanwhile is picked up after the exit (run_session_loop);
    #   a `chi --attach` finds no Bridge until then.
    # A restart keeps even an empty session (a new worker takes it over at
    # once) and leaves the recap to the conversation's next real pause.
    def left(result)
      return result if result == :restart

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

    # A human's input (ClientId.human?) un-archives the session;
    # a delegate's, a plugin's or a reminder's doesn't.
    # It also resets the delegate-report wakes (budget and pause).
    def user_input(client_id)
      return unless ClientId.human?(client_id)

      ArchiveStore.user_input(@session_id, state_dir: @state_dir)
      @wakes.human_input!
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
