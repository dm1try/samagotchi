# frozen_string_literal: true

require "fileutils"

require_relative "client_id"
require_relative "config"
require_relative "engine"
require_relative "guardrails/parent_policy"
require_relative "events"
require_relative "session"
require_relative "session_inbox"
require_relative "turn_note"
require_relative "steer"
require_relative "turn_origin"
require_relative "worker_idle_exit"
require_relative "worker_wakes"
require_relative "worker_inbound"
require_relative "worker_signals"
require_relative "worker_task_wakes"
require_relative "session_manager"
require_relative "archive_store"
require_relative "log"
require_relative "turn_flow"
require_relative "turn_checkpoint"
require_relative "llm/errors"
require_relative "continue_offer"
require_relative "iteration_limit"
require_relative "session_commands"
require_relative "session_setting"
require_relative "queued_command"
require_relative "model_profile"
require_relative "child_reports"
require_relative "child_move"
require_relative "context_absorber"
require_relative "context_poller"
require_relative "task_watch"
require_relative "tools/task_runtime"
require_relative "participants"
require_relative "participant_name"

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
  #
  # A TERM, HUP or INT (WorkerSignals, trapped in a spawned worker only)
  # stops the running turn as a Stop does (reason :signal), the turn's
  # work is saved as after any Stop, and the worker leaves (:signal) taking
  # no new work. A turn that hasn't ended SIGNAL_GRACE seconds after the
  # signal is cut: the session is saved as it is and the signal raised in
  # the loop's thread, as Ruby's default would (the teardown still runs).
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
    # /exit held by background tasks a finish wake waits for: how to end them.
    TASK_STOP_HINT = "stop one with the web's stop-task button or by asking for task_stop"
    # !rollback mid-turn would mean "the turn I'm in".
    ROLLBACK_BUSY_OUTPUT = "busy: Ctrl-C the turn first, then !rollback"
    # How long a signalled worker's turn has to end (it is canceled at once,
    # and again every SIGNAL_RETRY until it ends: a signal that lands just
    # before the turn begins finds none to cancel).
    SIGNAL_GRACE = 3.0
    # A second signal, or a TERM after `chi sessions stop` marked the
    # session stopped (that stop already canceled over the Bridge and waits
    # only seconds for the lock): this much.
    SIGNAL_SHORT_GRACE = 0.5
    SIGNAL_RETRY = 0.1
    # After the grace ran out and the signal was raised: the process ends
    # this much later at the latest (a teardown that hangs).
    SIGNAL_HARD_EXIT = 10.0

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
    # @param signals [WorkerSignals, WorkerSignals::None] the process's
    #   trapped signals (SessionManager.run_session_loop); none by default
    # @param signal_grace [Array(Numeric, Numeric, Numeric)] the grace, the
    #   short grace and the hard exit's delay (specs shorten them)
    # @param owner_lock [OwnerLock, nil] the session's, which this process
    #   holds (SessionManager.run_session_loop): marked leaving as the Bridge
    #   stops, so an attach waits for the recap on leave (OwnerLock.await_release)
    def initialize(session_id:, state_dir:, session_dir:, idle_exit_minutes: nil, poll_interval: nil,
                   signals: WorkerSignals::NONE, signal_grace: [SIGNAL_GRACE, SIGNAL_SHORT_GRACE, SIGNAL_HARD_EXIT],
                   owner_lock: nil)
      @session_id = session_id
      @owner_lock = owner_lock
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
      # The lines the running turn's drain merged ([prompt, TurnOrigin]), for a
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
      @signals = signals
      @signal_grace, @signal_short_grace, @signal_hard_exit = signal_grace
      # Set as the loop starts, and as it returns (or raises): a signal's
      # grace runs out only in between.
      @loop_started = false
      @left_loop = false
      @signal_mutex = Mutex.new
      @grace_expired = false
      # The running turn has ended (its end event) and its after_turn hooks
      # run: a signal's grace waits for them (#signalled).
      @turn_ending = false
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
    #   (chi stop), :signal when a signal stopped it (WorkerSignals),
    #   :crashed when the loop raised (the session is marked errored);
    #   SessionManager.run_session_loop turns it into the exit
    def run
      # The thread a signal's expired grace raises in (the main thread in a
      # worker process).
      @run_thread = Thread.current
      @signals.on_signal { |name, count| signalled(name, count) }
      start
      serve
      # That raise lands in the loop only (#signal_grace_expired arms once
      # it started, and never after it left): the teardown always runs
      # whole, a raise already on its way waits until it is done.
      Thread.handle_interrupt(SignalException => :never) do
        Thread.handle_interrupt(SignalException => :immediate) { run_loop }
      rescue StandardError => e
        crashed(e)
      ensure
        @signal_mutex.synchronize { @left_loop = true }
        teardown
      end
    end

    private

    # @return [Symbol] what #run returns
    def run_loop
      @signal_mutex.synchronize { @loop_started = true }
      # A session stopped before this worker took the lock (e.g. a stop
      # right after create) must not run its initial prompt.
      return :stopped if stopped_on_disk?
      return signal_leave if signalled?

      start_background
      loop do
        leaving = pass
        return leaving if leaving
      end
    end

    # The session, its Engine and what runs its turns, before anyone can
    # reach it.
    def start
      # The wake turns' budget (delegate reports, attached context, peers), from now.
      @wakes = WorkerWakes.new(grace: WAKE_START_GRACE)
      # This worker holds the session now (a continue's starting marker held
      # off any other until it did), and a continue that died moving
      # delegates here left its intent: finish it.
      ChildMove.clear_starting(@session_id, state_dir: @state_dir)
      ChildMove.adopt(@session_id, state_dir: @state_dir)
      @session = Session.load(@session_id, state_dir: @state_dir)
      drop_dead_question
      # The running turn, on disk at its iteration boundaries.
      @checkpoint = TurnCheckpoint.new(session: @session, state_dir: @state_dir)
      @engine = build_engine
      @config_restart_unsubscribe = ConfigFile.watch_restart_settings!(process: :worker) do |message|
        @engine.announce(type: :hook_notice, hook: "config", text: message, level: :warn, between_turns: true)
      end
      prune_tombstones
      settle_interrupted_turn
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      @engine.session = @session
      # Who is in the review as the worker starts: no notice for them
      # (#watch_participants announces the changes from here on).
      watch_participants
      # Input already waiting in the inbox starts the next turn at once, and
      # a command queued mid-turn (/thinking, /model, /llm-context) changes
      # what it starts with: no turn-end warm-up then.
      @engine.next_turn_waiting = lambda {
        !@command_queue.empty? || SessionInbox.find_new_input_files(@session_dir).any? || wake_due? || @task_wakes.due?
      }
      @turn_flow = TurnFlow.new(engine: @engine)
      # Its question's answer is queued as the matching /continue (the
      # Bridge exists by the time anyone answers).
      @continue_offer = ContinueOffer.new(engine: @engine, turn_flow: @turn_flow, run_turn: method(:run_engine_turn),
                                          max_iterations: method(:max_iterations),
                                          participant_refused: method(:participant_refusal),
                                          save: -> { save_or_log(:command) { save_session } },
                                          queue_command: lambda { |line, client_id:|
                                            @bridge.queue_command(line, client_id: client_id, card: true)
                                          })
      # A recap written while a continue offer waits says the turn stopped
      # unfinished (before the idle jobs start).
      @engine.recap_awaiting_continue = -> { @turn_flow.awaiting_continue? }
      # The seq of the last turn's end event: a command queued before it was
      # queued while that turn ran.
      @turn_end_seq = 0
      # The background tasks this session started and hasn't seen finish:
      # one that finishes unseen wakes the idle session (#run_task_wake).
      @task_wakes = WorkerTaskWakes.new(engine: @engine, session: @session, wakes: @wakes,
                                        awaiting_continue: -> { @turn_flow.awaiting_continue? },
                                        idle: -> { nothing_queued? && !@exit_requested },
                                        save: -> { save_or_log(:task_notes) { save_session } })
      @engine.subscribe(observer: lambda { |event|
        if Events::TURN_END.include?(event[:type])
          @turn_end_seq = event[:event_seq]
          @turn_end_type = event[:type]
          @turn_ending = true
        end
        if event[:type] == :turn_started
          @turn_id = event[:turn_id]
          @turn_ending = false
        end
        ring_question(event) if event[:type] == :question_requested
        @task_wakes.observe(event)
      })
      # This session's own delegate children's news (rings in children/).
      @child_reports = ChildReports.new(session_id: @session_id, state_dir: @state_dir,
                                        predecessor: @session.continues)
      # Its attached context's notes (ContextSources).
      @context_absorber = ContextAbsorber.new(session_id: @session_id, state_dir: @state_dir,
                                              project_root: @session.project_root,
                                              peer_sources: @engine.peer_sources, peer_turns: -> { @wakes.peer_turns })
      # What comes in between turns, and how each kind is saved.
      @inbound = WorkerInbound.new(session: @session, state_dir: @state_dir, session_dir: @session_dir, engine: @engine,
                                   context_absorber: @context_absorber, wakes: @wakes,
                                   awaiting_continue: -> { @turn_flow.awaiting_continue? },
                                   stopped: -> { stopped_on_disk? },
                                   queue_command: lambda { |line, client_id, after_file, enqueued_id, author: nil|
                                     @bridge.queue_command(line, client_id: client_id, after_file: after_file,
                                                                 enqueued_id: enqueued_id, author: author)
                                   })
      # /model's default is the config's, as in the REPL; the Engine started
      # on the session's model.  nil when there is no default.model.
      @default_model = ModelProfile.default_model_name
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
      announce_session_warnings
      @idle_exit = WorkerIdleExit.new(
        engine: @engine, bridge: @bridge,
        timeout_minutes: @idle_exit_minutes || SessionManager.config_idle_exit_minutes,
        input_pending: method(:input_pending?),
        awaiting_continue: -> { @turn_flow.awaiting_continue? },
        running_tasks: -> { Tools::TaskRuntime.running_created_in(@engine.messages_checkpoint) },
        # Only when a finish would wake the session (D3): with queue its end
        # is just a note, not worth keeping the worker up for. One that
        # finished since the pass looked holds too, until the next pass
        # wakes for it (#run_task_wake).
        watched_tasks: -> { TaskWatch.mode == "wake" ? @task_wakes.watch.holding : [] },
        watched_running: -> { TaskWatch.mode == "wake" ? @task_wakes.watch.running : [] }
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
      # A signalled worker takes no new work.
      return signal_leave if signalled?

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

      # A participant's input waits while the owner's Continue offer
      # stands (#run_input_files): with only theirs, the loop idles.
      input_files = SessionInbox.find_new_input_files(@session_dir).reject { |file| held_for_offer?(file) }
      return idle_pass if input_files.empty?
      # A command queued since the look above, before these prompts were
      # written (an answer's /continue yes, then a prompt), still runs
      # first; the next pass takes the prompts.
      return if run_queued_commands

      run_input_files(input_files)
    end

    # Nothing queued: a delegate wake turn, a task finish wake turn or a due
    # reminder runs, else the worker leaves when the idle exit or a client's
    # exit is due, else it sleeps until woken or the fallback tick.
    # @return [Symbol, nil] as #pass
    def idle_pass
      return if run_wake_turn
      return if run_task_wake
      return if run_due_reminders
      return left(:idle_exit) if @idle_exit.due? && leave_idle
      return left(@exit_restart ? :restart : :exit_requested) if @exit_requested && leave_on_request

      watch_participants
      @waker.wait(idle_wait)
      nil
    end

    # A participant invited, revoked or expired since the last look: the
    # UIs hear it (Engine#announce_participants: :participants_changed).
    # Between turns, at most once a fallback tick; a failure only logs.
    def watch_participants
      @engine.announce_participants
    rescue StandardError => e
      Log.warn(:worker, "participants_watch_failed", error: e.class.name)
    end

    # A participant's input file is held (left in the inbox, still queued
    # and counted as theirs) while the owner's Continue offer stands: the
    # offer is the owner's to answer (continue, stop, or a turn of their
    # own, which drops it), never dropped by a participant's turn. Once
    # one is held, the batch's later participant files wait with it, and
    # the batch ends after the next turn that runs: the next pass takes
    # the held ones in order (each checked against participants.json and
    # the cap as it starts, #run_prompt).
    # @return [nil]
    def run_input_files(input_files)
      held = false
      input_files.sort.each do |input_file|
        # A stop (or a signal) between two queued turns leaves the rest queued.
        break if signalled? || stopped_on_disk?

        # Commands that came before this file (D1: a queued /model X sent
        # before this prompt, a command an earlier file carried) run first.
        run_queued_commands
        @inbound.absorb_notes
        if held ? SessionInbox.participant_input?(input_file) : held_for_offer?(input_file)
          held = true
          next
        end
        run_input_file(input_file)
        break if held
      end
      nil
    end

    # Whether a command or an input file waits to run (WorkerIdleExit's
    # :input_queued). A participant's file held for the Continue offer
    # (#held_for_offer?) doesn't count: what waits is the owner's answer,
    # the policy's :continue_offered.
    def input_pending?
      !@command_queue.empty? || SessionInbox.find_new_input_files(@session_dir).any? { |file| !held_for_offer?(file) }
    end

    # Whether +input_file+ waits for the owner's answer to the Continue
    # offer that stands (#run_input_files).
    def held_for_offer?(input_file) = @turn_flow&.awaiting_continue? && SessionInbox.participant_input?(input_file)

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
      @config_restart_unsubscribe&.call
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
        appended_prompt_files: @session.appended_prompt_files,
        # The finish wake reports a task the model leaves running: the tool
        # descriptions say so, fixed for this worker (a stable prompt prefix).
        task_finish_notes: TaskWatch.mode != "off",
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

    # A turn an earlier worker died in (TurnCheckpoint's mark in the file):
    # ended now as canceled, with its note, and saved, before the Bridge
    # serves the session (TurnCheckpoint.settle). Its queued id's wait
    # (chi send --queue --wait) reads the end it records in the session dir.
    def settle_interrupted_turn
      mark = TurnCheckpoint.settle(@session, session_dir: @session_dir)
      return unless mark

      Log.info(:worker, "interrupted_turn_settled", turn_id: mark.id, iteration: mark.iteration, at: mark.at)
      save_or_log(:interrupted_turn) { save_session }
    end

    # The per-input tombstones (removed, settled) older than
    # SessionInbox::TOMBSTONE_MAX_AGE, once per worker start: they only go
    # with the session dir otherwise.
    def prune_tombstones
      removed = SessionInbox.prune_removed(@session_dir)
      settled = TurnCheckpoint.prune_settled(@session_dir)
      Log.info(:worker, "tombstones_pruned", removed: removed, settled: settled) if (removed + settled).positive?
    end

    # A saved parent_answers that isn't a level reads as hard on every
    # answer without a word; said once here, as the session loads.
    def announce_session_warnings
      value = @session.parent_answers
      return unless Guardrails::ParentPolicy.unknown_level?(value)

      @engine.announce({ type: :guardrail_warning, label: "parent_answers",
                         message: "parent_answers #{value.inspect} in session #{@session_id} isn't hard/standard/soft; hard applies" })
    end

    # A question saved by a worker that died while it waited (an
    # ask_user_question, an approval, a hook's question): the turn that
    # asked is gone, so nobody can answer it, and left in the file it
    # would keep the hub's "needs you" badge on for good. Dropped and saved
    # before the Engine and the Bridge exist (no question lock, no events).
    def drop_dead_question
      id = @session.drop_dead_question
      return unless id

      Log.info(:worker, "dead_question_dropped", id: id)
      save_or_log(:dead_question) { save_session }
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
    # delegate report's wake turn (#run_wake): it counts toward
    # session.max_wakes (a peer's answer toward context.peer_turns too,
    # unless it agrees).
    # +context_wake+: a WorkerInbound::ContextWake.
    def run_context_wake_turn(context_wake)
      name = context_wake.name
      Log.info(:worker, "context_wake_turn", name: name, in_a_row: @wakes.count!(peer: context_wake.peer_turn?))
      run_wake(origin: context_wake.origin, failed: "the change in attached context #{name}", mark: context_wake)
    end

    # The first prompt (spawn_session's): a delegate child's task, which is
    # its parent's although no client sent it. Its turn carries the id
    # spawn_session gave it, so a wait for it (--new --wait) names it.
    def run_initial_prompt(prompt)
      @initial_turn = true
      run_prompt(WorkerInbound::Prompt.new(text: prompt, origin: TurnOrigin.new(enqueued_id: @session.first_turn_id)))
    ensure
      @initial_turn = false
    end

    def run_input_file(input_file)
      @inbound.take_input(input_file) { |prompt| run_prompt(prompt) }
    end

    # @param prompt [WorkerInbound::Prompt]
    def run_prompt(prompt)
      origin = prompt.origin
      # A participant's turn queued before their link ended or their cap was
      # reached doesn't start (chi web refuses new ones; this is the
      # worker's check).
      if (reason = participant_refusal(origin.author))
        return refuse_participant_turn(origin, reason)
      end

      # A first turn sees the context attached before it, and any turn the
      # background tasks that finished since the last look.
      absorb_context(before_turn: true)
      @task_wakes.absorb
      user_input(origin.client_id)
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
      participant_refusal(origin.author)
    end

    # Why the participant +author+ ("p:<id>") may run no more turns, nil
    # while they may (and for the owner): "revoked" when participants.json
    # has no active entry for them (revoked, expired, never invited),
    # "cap_reached" once they spent their cap (its own, else the config's;
    # their turns and the side requests they caused, Engine#metrics). The
    # owner hears the cap once per cap (#cap_notice).
    def participant_refusal(author)
      author = Steer.sender_author(author) or return nil

      entry = Participants.read(@session_id, state_dir: @state_dir).find { |e| Steer.author_for(e.id) == author }
      return "revoked" unless entry&.active?(Time.now)

      cap = entry.cap.is_a?(Numeric) ? entry.cap.to_f : Web::Grants.default_cap
      return nil if @engine.metrics.spend(author) < cap

      cap_notice(author, entry.name, cap)
      "cap_reached"
    end

    # The owner's notice that a participant reached their cap: once per
    # participant and cap (a raised cap that is reached again says so again).
    def cap_notice(author, name, cap)
      key = [author, cap]
      return if (@cap_noticed ||= Set.new).include?(key)

      @cap_noticed << key
      id = Steer.participant_id(author)
      who = ParticipantName.clean(name)
      @engine.announce(type: :hook_notice, hook: "participants", level: :warn, between_turns: true,
                       text: format(CAP_NOTICE, name: who.empty? ? id : who, cap: cap, session: @session_id[0, 8], id: id))
    end

    CAP_NOTICE = "%<name>s reached their $%<cap>.2f review cap: their comments are refused until you raise it " \
                 "(chi share cap %<session>s %<id>s AMOUNT)."

    # A participant's queued turn that may not start (#participant_refusal):
    # taken off the queue (:turn_dequeued, so every UI drops its bubble)
    # and audited; it never runs. Its settled record (canceled, the reason)
    # ends the sender's wait on it (chi send --wait, chi web's /wait).
    # @param origin [TurnOrigin] a participant's
    def refuse_participant_turn(origin, reason)
      TurnCheckpoint.record_refused(@session_dir, origin.enqueued_id, reason: reason)
      Participants.log(@session_id, :turn, state_dir: @state_dir, participant: origin.participant_id,
                                           enqueued_id: origin.enqueued_id, status: "refused", reason: reason)
      @engine.announce(type: :turn_dequeued, enqueued_id: origin.enqueued_id, client_id: origin.client_id)
      nil
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

      @continue_offer.drop(REMINDER_ORIGIN)
      # A failure has no prompt to hand back (the Engine announced
      # :turn_failed). The offer went before the turn
      # (ContinueOffer#drop); either way the rollback window closes.
      run_engine_turn(nil, continue: true, origin: REMINDER_ORIGIN,
                           max_iterations: IterationLimit.for) { @turn_flow.after_reminder_turn }
      true
    end

    # A reminder turn's origin: chi's own (system:reminder).
    REMINDER_ORIGIN = TurnOrigin.new(client_id: ClientId::REMINDER)

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

      # Unresolved: a relay among them opens its card at the turn's first
      # boundary, on the turn thread (a Stop closes it).
      reports, = take_child_reports(resolve: false)
      # The turn must not generate with nothing to say: the drain gets this
      # exact list at its first boundary.
      return false if reports.empty?

      @wakes.hand_over(reports)
      Log.info(:worker, "delegate_wake_turn", reports: reports.size, in_a_row: @wakes.count!)
      # Rolled back, the rings stay (settle_child_reports): the user's next
      # turn takes them. A turn that got somewhere stays, and read them.
      run_wake(origin: reports.first.origin,
               failed: reports.size == 1 ? "a delegate's report" : "#{reports.size} delegate reports",
               kept: "chi keeps #{reports.size == 1 ? "the report and brings it" : "the reports and brings them"} " \
                     "again with the user's next message.")
      true
    ensure
      @wakes.drop_handed
    end

    # A wake turn (a delegate report's, an attached context change's, a
    # finished task's): a continue turn nobody typed, from +origin+. A
    # failure goes back to before the turn and pauses wakes until a human's
    # input (a provider outage doesn't loop); so does a Stop before it got
    # anywhere (a Stop or a before_turn hook's cancel before the model
    # call, restored by TurnFlow), rather than waking again at once. Either
    # way +mark+ (a WorkerInbound::ContextWake or TaskWake: its wake note,
    # the turn's first message) goes back to a plain note
    # (WorkerInbound#unmark_wake), unless the failed turn kept its steps.
    # +failed+ names the wake in the failed turn's note, +kept+ says what
    # happens to it (TurnFlow#prompt_turn_failed).
    def run_wake(origin:, failed:, kept: nil, mark: nil)
      @turn_flow.before_prompt_turn
      restores = @turn_flow.restores
      run_engine_turn(nil, continue: true, origin: origin, id: mark&.turn_id,
                           max_iterations: IterationLimit.for) do |result, error|
        if error
          steps_kept = @turn_flow.prompt_turn_failed(error: error, wake: failed, wake_kept: kept) == :kept
          @inbound.unmark_wake(mark) if mark && !steps_kept
          @wakes.pause!
        else
          @continue_offer.after_turn(result)
          if result.canceled? && @turn_flow.restores != restores
            @inbound.unmark_wake(mark) if mark
            @wakes.pause!
          end
        end
      end
    end

    # The background tasks this session started that finished unseen, as
    # notes (WorkerTaskWakes#take), and the wake turn the first one may
    # start.
    # @return [Boolean] whether a wake turn ran
    def run_task_wake
      task_wake = @task_wakes.take
      return false unless task_wake

      run_task_wake_turn(task_wake)
      true
    end

    # A turn nobody typed for a finished task: a continue turn from
    # task:<id> whose first message is the wake note, on the delegate wake's
    # rules (#run_wake; counted toward session.max_wakes): a failure that
    # kept nothing, or a Stop that restored the conversation, leaves the
    # note as a plain one (M4).
    def run_task_wake_turn(task_wake)
      Log.info(:worker, "task_wake_turn", task_id: task_wake.id, in_a_row: @wakes.count!)
      run_wake(origin: task_wake.origin, failed: "a finished background task (#{task_wake.name.delete_prefix("task ")})",
               kept: "Its note stays for the user's next message.", mark: task_wake)
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
      # A signalled worker runs no more (a /continue would start a turn).
      while !signalled? && (command = next_ready_command)
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

    # A participant's file held for the Continue offer (#run_input_files)
    # doesn't hold a command back: that command may be the owner's answer.
    def ready_command?(command)
      return true if command.after_file.nil?

      SessionInbox.find_new_input_files(@session_dir).none? do |path|
        File.basename(path) <= command.after_file && !held_for_offer?(path)
      end
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
        announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                  confirm: result.confirm)
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
      @engine.holding_announcements do
        command_result(command) do
          @commands.run(command.line, confirm: confirm?(command), as_parent: as_parent?(command), user_ui: user_ui?(command))
        end
      end
    end

    # Whether +command+ asks before a costly /thinking or /reasoning-history
    # change (CacheConfirm): only a person at a web tab or a TUI sees the
    # question; chi send, a delegate, a plugin and a card's action apply it.
    def confirm?(command) = ClientId.interactive?(command.client_id) && !command.card

    # Whether +command+ is a parent agent's (chi answer's marker, which chi
    # send and a parent's attach give a /continue yes too): held to
    # guardrails.parent_answers (SessionCommands#continue_answer).
    def as_parent?(command) = command.client_id.to_s == ClientId::CLI_ANSWER

    # Whether +command+ is a user's at a UI (a web tab, a chi TUI, a card's
    # click), not a parent agent's: only such a line loosens
    # /parent-answers. chi send, a delegate's follow-up, a plugin and an
    # input with no client never do (ParentAnswersCommand).
    def user_ui?(command) = ClientId.interactive?(command.client_id) && !as_parent?(command)

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
    # copies (ctx.messages) and shows things through ctx only. One that
    # changed the session (/title, /recap off: fields no turn writes) is
    # saved here, as a queued one is (#run_command), through Session#save,
    # which takes the session's lock and writes a running turn's checkpoint
    # (as WorkerSignals' save off the turn thread does), so the turn's own
    # saves keep it.
    def start_anytime_command(command)
      @engine.spawn_anytime do
        result = command_result(command) { @engine.running_anytime { @commands.run(command.line, confirm: confirm?(command)) } }
        # Saved before its command_ran: a client that reads the file on the reply finds it.
        save_or_log(:command) { save_session } unless Array(result.changed).empty?
        announce_command(command, status: result.status.to_s, output: result.output, changed: Array(result.changed),
                                  anytime: true, confirm: result.confirm)
      rescue StandardError => e
        Log.warn(:worker, "anytime_command_failed", line: command.line, error: e.class.name, msg: e.message)
      end
    end

    # @param anytime [Boolean] an anytime command's: its line was shown at
    #   its command_queued already
    # @param confirm [CacheConfirm::Confirm, nil] the change asks first: the
    #   line that applies it (the TUI's prefill, the web's Apply button)
    def announce_command(command, status:, output:, changed:, anytime: false, confirm: nil)
      TurnCheckpoint.record_command_outcome(@session_dir, command.enqueued_id, status: status)
      text = output.to_s
      event = { type: :command_ran, **command.event_fields, status: status, output: text[0, COMMAND_OUTPUT_LIMIT],
                changed: changed.map(&:to_s), model_name: @engine.effective_model_name }
      event[:anytime] = true if anytime
      # The session's title after /title (nil: cleared), for the TUIs' row.
      event[:title] = @engine.session&.title if changed.include?(:title)
      # Its line was shown at its command_queued (waits: turn_end).
      event[:queued] = true if command.waits_for_turn_end?
      # The chips the command moved (SessionSetting#changed_by): what the next
      # turn runs under now (/llm-context, /thinking, /reasoning-history,
      # /toolkit, and /model for the model's).
      SessionSetting::ALL.each { |setting| event[setting.key] = setting.summary(@engine) if setting.changed_by?(changed) }
      event[:confirm] = confirm.to_h if confirm
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
      origin = TurnOrigin.of(turn_args[:origin])
      @reporting_turn = reports_to_parent?(origin)
      # A participant's review turn merges no input (#pending_input_drain).
      @participant_turn = origin.participant?
      restores = @turn_flow.restores
      begin
        @checkpoint.begin_turn(prompt: prompt, enqueued_id: origin.enqueued_id, author: turn_author_fields(origin))
        @session.status = Session::STATUS_RUNNING
        # A continue that moved this session to the chain's new link wrote
        # the new parent beside it (Session::PARENT_FILE): this turn's
        # status, its rings and every save from here on say so.
        @session.parent_id = Session.parent_override(@session_id, state_dir: @state_dir) || @session.parent_id
        save_session
        result = @engine.run_turn(@session, prompt, pending_input: pending_input_drain, **turn_args)
      rescue StandardError => e
        error = e
        # Still running: no turn of the Engine's ended (it never began).
        # It ends here, failed, as an Engine turn would record it: a wait
        # (ReplyWait) tells a turn's end by last_turn.
        if @session.status == Session::STATUS_RUNNING
          @session.status = Session::STATUS_IDLE
          @engine.record_last_turn(@session, "failed", 0, origin, { type: :turn_failed })
          Log.warn(:worker, "turn_not_begun", error: e.class.name, msg: e.message)
        end
      ensure
        # Ended (or never begun): the saves write the session's own messages.
        @checkpoint.end_turn
        refuse_queued_commands
      end
      yield result, error
      response = result&.output
      # A turn that ran out of iterations and asks whether to continue left
      # no reply: its text is what came before its last tool calls, and a
      # wait (chi send --wait) gets the question instead.
      unless response.nil? || response.strip.empty? || @continue_offer.awaiting?
        SessionInbox.write_output(@session_dir, response, enqueued_id: origin.enqueued_id)
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

      @initial_turn || @owes_parent || !ClientId.human?(origin.client_id)
    end

    # The Engine published a question (after the question desk saved it).
    # In a turn that reports to the parent, the model's own question, the
    # step-limit continue and a hook's question ring it (the parent reports
    # or relays a hook's: ChildReports). Approvals don't: the relay takes
    # them while the parent waits. Nor does a card relayed from this
    # session's own child (relay set): the hop is the parent's wait.
    def ring_question(event)
      return unless @reporting_turn

      pending = event[:pending_question] || {}
      kind = pending[:kind].to_s
      return unless RINGING_KINDS.include?(kind)
      return if pending[:relay]

      ChildRing.ring(@session, why: "question", state_dir: @state_dir)
      @asked_parent = true
    end

    # The kinds of question that ring a delegate child's parent (#ring_question).
    RINGING_KINDS = ["", ContinueOffer::KIND, "hook"].freeze

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
    # @param prompts [Array<Array(String, TurnOrigin|nil, Array|nil)>] [prompt,
    #   origin, images] (a web client gets its image chips back)
    # @param error [Exception, nil] what failed: its one line stays in the
    #   conversation as a turn note
    # Not saved here: run_engine_turn saves after its block.
    def restore_failed_turn(prompts, error: nil)
      @engine.synchronize_events do
        next if @turn_flow.prompt_turn_failed(error: error) == :kept

        prompts.each do |prompt, origin, images|
          restored = { type: :prompt_restored, prompt: prompt, origin: origin.wire }
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
        # A queued line or one with images runs as its own turn after this
        # one (steering merges text only): skipped here, not a barrier, so a
        # line sent after it still goes in at this boundary. Only the files
        # claimed below reach @merged_this_turn and the checkpoint.
        # A participant's review turn takes none: the owner's lines (the
        # Bridge queues them, this covers a file it didn't see) run as the
        # owner's own turns after it, never inside its review boundary.
        files = if @participant_turn
                  []
                else
                  SessionInbox.find_new_input_files(@session_dir).sort
                              .reject { |input_file| SessionInbox.waits_for_turn_end?(input_file) }
                end
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
        merged.each { |_prompt, origin| user_input(origin.client_id) }
        # Delegate children's reports: never handed back on a failure
        # (their rings stay for the next turn), so not in @merged_this_turn.
        reports, mark = take_child_reports
        unless merged.empty? && reports.empty?
          @engine.announce(type: :input_merged, count: merged.size + reports.size,
                           origins: (merged.map(&:last) + reports.map(&:origin)).filter_map(&:wire))
          @merged_this_turn.concat(merged)
        end
        # Each line keeps its sender (Steer.source_for_client): a chi send or
        # a delegating parent's line is saved and shown to the model as theirs,
        # a participant's with its author (Engine#author_fields).
        lines = merged.map { |prompt, origin| merged_line(prompt, origin) } + reports.map(&:line)
        # A wake turn starts with its first line, whoever sent it.
        lines[0] = lines[0].with(mark: mark) if mark && lines.any?
        # The turn so far, with what this boundary merges (its input files
        # are gone now), on disk at most every TurnCheckpoint::INTERVAL;
        # its metrics so far with it, so a turn a KILL ends keeps them.
        @engine.checkpoint_metrics if @checkpoint.boundary(@engine.live_conversation, merging: lines, turn_id: @turn_id)
        lines
      end
    end

    # A participant's author fields (Engine#author_fields), {} for the owner.
    def turn_author_fields(origin)
      origin.participant? ? @engine.author_fields(origin.author, session: @session) : {}
    end

    def merged_line(prompt, origin)
      author = turn_author_fields(origin)
      Steer::Line.new(text: prompt, source: Steer.source_for_client(origin.client_id),
                      author: author[:author], author_name: author[:author_name])
    end

    # The reports for rings that came in since the turn last looked. A
    # failure to read them must not take the turn's steering with it.
    # A wake turn's first call gets the reports it was started for (their
    # message is the turn's start: turn_start, turn_id, so a reload shows
    # the turn as its own).
    # @return [Array(Array<ChildReports::Report>, Hash|nil)] the reports
    #   and the mark of their message
    # A report whose question goes to the parent's user is relayed here
    # (ChildReports#resolve), before the boundary announces or merges
    # anything; one whose card a Stop closed is held back until a human's
    # input (no wake turn re-offers it at once; other wakes go on).
    # +resolve+ false: a wake turn's take before the turn starts.
    def take_child_reports(resolve: true)
      if (reports = @wakes.take_handed)
        return [resolve_relays(reports), { turn_start: true, turn_id: @turn_id }.compact]
      end

      taken = @child_reports.take
      [resolve ? resolve_relays(taken) : taken, nil]
    rescue StandardError => e
      Log.warn(:worker, "delegate_reports_failed", error: e.class.name, msg: e.message)
      [[], nil]
    end

    def resolve_relays(reports)
      return reports if reports.none?(&:relay)

      relay = @engine.relay_peer
      stopped = false
      reports.filter_map do |report|
        next report unless report.relay
        # The turn stopped on an earlier card: no more cards in it.
        next @child_reports.hold_back(report) if stopped

        @child_reports.resolve(report, relay: relay).tap { |resolved| stopped = resolved.nil? }
      end
    end

    # Check again with the event log held, which the Bridge holds while it
    # queues a POST /turn, then close the Bridge's intake so no client can
    # queue one after the check, and stop the idle jobs (reminder callback,
    # recap). The Bridge stops after the log is let go (#stop_bridge_after).
    # A client connecting from here on finds no worker: `chi --attach` fails
    # and the web stream answers 503 (a small window, left as is).
    # @return [Boolean] false when something came in since #due?
    def leave_idle
      stop_bridge_after do
        @engine.synchronize_events do
          next false unless @idle_exit.due?

          @bridge&.close_intake
          # Not joined: a recap tick's emit waits for the event log held here.
          @engine.stop_idle(join: false)
          log_idle_exit
          true
        end
      end
    end

    # The Bridge stops once the block (which closed its intake with the
    # event log held) answers true, outside the log: Bridge#stop waits for
    # the requests it is answering, and one waiting on the log would hold
    # it for the whole grace before being killed. The owner lock says it is
    # leaving first, so a client that finds no Bridge from here on waits
    # for the lock (OwnerLock.await_release) instead of giving up.
    # @return [Boolean] what the block answered
    def stop_bridge_after
      leaving = yield
      if leaving
        mark_leaving
        @bridge&.stop
      end
      leaving
    end

    # How long the lock stays held after the Bridge: the recap on leave's
    # timeout (#left), none for a restart (#left writes none). A delete
    # writes none either, but the bound only has to be an upper one.
    def mark_leaving
      @owner_lock&.mark_leaving(wait: @exit_restart ? 0 : @engine.recap_timeout.to_f)
    rescue StandardError => e
      Log.warn(:worker, "mark_leaving_failed", error: e.class.name, msg: e.message)
    end

    # Bridge POST /exit, on a Bridge thread with the event log held.
    # +delete+: the session is deleted after (/exit --delete), so no recap.
    # +restart+: a new worker takes over (on the newest chi installed), so
    # WorkerIdleExit#hold_for_restart's rules, and no recap or discard.
    # @return [WorkerIdleExit::Hold, nil] what keeps the worker up (for
    #   :background_tasks, the watched tasks still running), nil when it
    #   will leave
    def exit_request(client_id, delete: false, restart: false)
      # The Bridge serves before the idle-exit policy exists.
      return WorkerIdleExit::Hold.new(reason: :starting) unless @idle_exit

      if restart
        hold = @idle_exit.hold_for_restart
        return WorkerIdleExit::Hold.new(reason: hold) if hold
      else
        # /exit names the tasks it waits for (D3), from the one look that found them.
        hold = @idle_exit.request_hold(requester: client_id, hint: TASK_STOP_HINT)
        return hold if hold
      end

      @exit_requested = true
      @exit_requested_by = client_id
      @exit_deletes = delete && !restart
      @exit_restart = restart
      @waker.wake
      nil
    end

    # #leave_idle for an exit a client asked for: check again with the event
    # log held (a prompt may have come in since), then close the Bridge's
    # intake and stop the idle jobs (the Bridge stops after the log). Other clients' streams no longer hold: the asker's
    # may not have closed yet, and a UI joining now finds the worker gone
    # (:stream_closed), the window #leave_idle has too.
    # @return [Boolean] false when something came in since the request
    def leave_on_request
      stop_bridge_after do
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

          @bridge&.close_intake
          # Not joined: a recap tick's emit waits for the event log held here.
          @engine.stop_idle(join: false)
          Log.info(:worker, @exit_restart ? "restart_requested" : "exit_requested", by: @exit_requested_by || "a client")
          true
        end
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
      deleting = result == :exit_requested && @exit_deletes
      # The watch goes with this process: a task that finished since the
      # last look (nothing held the exit for it: queue, a note-only task,
      # /exit) is a plain note for the next turn, not lost. Not into a
      # session /exit --delete deletes next: its save could land after the
      # delete and write the session back.
      @task_wakes.absorb unless deleting
      return result if result == :restart

      @discard = empty_session?
      write_recap_on_leave unless @discard || deleting
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
    # a delegate's, a plugin's or a reminder's doesn't, and a participant's
    # doesn't either: it is no owner's input.
    # It also resets the wakes (budget and pause); input typed in the web or
    # a TUI the peer wakes too (chi send doesn't: a peer can run it).
    def user_input(client_id)
      return unless ClientId.human?(client_id) && !ClientId.review?(client_id)

      ArchiveStore.user_input(@session_id, state_dir: @state_dir)
      @wakes.human_input!(interactive: ClientId.interactive?(client_id))
      @child_reports&.release_holds
    end

    def stopped_on_disk?
      SessionManager.stopped_on_disk?(@session_id, state_dir: @state_dir)
    end

    # Save the session, a stopped one too: a stop is the marker file
    # (Session.mark_stopped), which every load reads over the saved status,
    # so this save can't hide it, and the turn the stop canceled is kept.
    # Session#save serializes it with every other save of @session (Bridge
    # threads, the turn's checkpoints, a signal's thread).
    def save_session
      @session.save(state_dir: @state_dir)
    end

    def signalled? = !@signals.signal.nil?

    # @return [Symbol] :stopped when the session was stopped too (chi
    #   sessions stop TERMs its worker), else :signal
    def signal_leave
      Session.stopped_marker?(@session_id, state_dir: @state_dir) ? :stopped : :signal
    end

    # A signal (WorkerSignals#fire), on a thread of its own: the loop wakes
    # (an idle worker leaves at once), the running turn is canceled as a
    # Stop (again every SIGNAL_RETRY, until the loop has left), and when
    # the grace runs out first, #signal_grace_expired. A turn that has
    # ended and runs its after_turn hooks (which store the answer's display
    # and refs) is no longer canceled, and gets until SIGNAL_HARD_EXIT
    # past the grace, the worker's own end of the turn (its saves, after
    # the turn stopped running) too: the loop leaves next. A grace that runs out before the loop started waits
    # for it (the loop's first look leaves). A signal after the loop left
    # (the teardown, the caller's last steps) only brings the hard exit.
    def signalled(name, count)
      Log.info(:worker, "signal", signal: name, count: count, turn_running: @engine&.turn_running? || false)
      return signal_hard_exit if @left_loop

      @waker.wake
      short = count > 1 || Session.stopped_marker?(@session_id, state_dir: @state_dir)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      deadline = now + (short ? @signal_short_grace : @signal_grace)
      hooks_deadline = deadline + @signal_hard_exit
      ended = false
      until @left_loop
        running = @engine&.turn_running?
        ended ||= running && @turn_ending
        @engine.cancel_current_turn!(:signal) if running && !ended
        break if @loop_started && Process.clock_gettime(Process::CLOCK_MONOTONIC) >= (ended ? hooks_deadline : deadline)

        sleep(SIGNAL_RETRY)
      end
      signal_grace_expired(name) unless @left_loop
    rescue StandardError => e
      Log.warn(:worker, "signal_failed", signal: name, error: e.class.name, msg: e.message)
    end

    # The process ends SIGNAL_HARD_EXIT from now at the latest.
    def signal_hard_exit
      sleep(@signal_hard_exit)
      @signals.hard_exit
    end

    # The turn didn't end in time (a tool that ignores the cancel, slow
    # after_turn hooks): the session is saved as it is now (a turn that has
    # ended: with it), and the signal raised in the loop's thread, so
    # Worker#run's teardown and the lock's release still run. The process
    # ends SIGNAL_HARD_EXIT later at the latest. Once, whatever the signals.
    def signal_grace_expired(name)
      expired = @signal_mutex.synchronize { !@grace_expired && !@left_loop && (@grace_expired = true) }
      return unless expired

      Log.warn(:worker, "signal_grace_expired", signal: name, turn_running: @engine&.turn_running? || false)
      save_or_log(:signal) { save_session }
      # Not once the loop has left (it may have, during the save).
      @signal_mutex.synchronize { @run_thread&.raise(SignalException.new(name)) unless @left_loop }
      signal_hard_exit
    end
  end
end
