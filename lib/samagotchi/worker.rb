# frozen_string_literal: true

require "fileutils"
require "securerandom"

require_relative "client_id"
require_relative "config"
require_relative "engine"
require_relative "events"
require_relative "session"
require_relative "session_inbox"
require_relative "turn_note"
require_relative "steer"
require_relative "turn_origin"
require_relative "worker_idle_exit"
require_relative "degrade"
require_relative "hold_stop"
require_relative "children_status"
require_relative "worker_wakes"
require_relative "worker_inbound"
require_relative "worker_signals"
require_relative "worker_task_wakes"
require_relative "session_manager"
require_relative "archive_store"
require_relative "reminder_carry"
require_relative "log"
require_relative "turn_flow"
require_relative "turn_checkpoint"
require_relative "reply_for"
require_relative "continue_offer"
require_relative "iteration_limit"
require_relative "session_commands"
require_relative "queued_command"
require_relative "model_profile"
require_relative "child_reports"
require_relative "child_move"
require_relative "starting_marker"
require_relative "context_absorber"
require_relative "context_candidates"
require_relative "context_poller"
require_relative "task_watch"
require_relative "tools/task_runtime"
require_relative "worker_participant_gate"
require_relative "worker_exit_claim"
require_relative "worker/leave"
require_relative "worker/wake_turns"
require_relative "worker/startup"
require_relative "worker/signal_grace"
require_relative "worker/scratch"
require_relative "worker/child_side"
require_relative "worker/command_queue"
require_relative "worker/block_fixes"
require_relative "worker/senders"
require_relative "worker/mail"

module Samagotchi
  # The loop of a background session worker, once it owns the session (see
  # WorkerBoot.run_session_loop, which takes the OwnerLock around #run).
  #
  # It runs the session's Engine and Bridge, takes queued prompts from the
  # input dir one turn at a time, and returns when nobody has used it for the
  # idle-exit timeout. A failed turn is rolled back and its prompt handed back
  # (:prompt_restored), and the loop goes on. A stop marked on
  # disk exits the process; an error outside a turn marks the session and
  # exits with 1.
  #
  # The file IPC stays behind SessionInbox's functions (find_new_input_files,
  # claim_input_file, ...) and the Bridge behind #start_bridge, which specs
  # stub as seams.
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
  #
  # This file keeps the loop, the wiring, the prompt turns and the steering
  # drain. Eight concerns are parts, lib/samagotchi/worker/<concern>.rb
  # holding Worker::<Concern>Part, included here (they share Worker's ivars):
  # LeavePart (exit and leave), WakeTurnsPart (the turns nobody typed),
  # StartupPart (the start-up settle), SignalGracePart (a signal's grace),
  # ScratchPart (a scratch worker whose terminal left), ChildSidePart (a
  # delegate child's rings, Verify fresh verdicts), CommandQueuePart
  # (session commands between turns) and BlockFixesPart (a failed block's
  # fix, between turns).
  class Worker
    include LeavePart
    include WakeTurnsPart
    include StartupPart
    include SignalGracePart
    include ScratchPart
    include ChildSidePart
    include CommandQueuePart
    include BlockFixesPart
    include SendersPart
    include MailPart

    FALLBACK_TICK_SECONDS = 5
    # A worker just started runs no wake turn for delegate reports this
    # long: a worker spawned for a message (chi send to a stopped parent)
    # gets it over the Bridge a moment after it starts, and that message's
    # turn goes first (the reports join it).
    WAKE_START_GRACE = 2.0

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
    #   trapped signals (WorkerBoot.run_session_loop); none by default
    # @param signal_grace [Array(Numeric, Numeric, Numeric)] the grace, the
    #   short grace and the hard exit's delay (specs shorten them)
    # @param owner_lock [OwnerLock, nil] the session's, which this process
    #   holds (WorkerBoot.run_session_loop): marked leaving as the Bridge
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
      # Set as it leaves: nothing happened in the session (#discard?).
      @discard = false
      @marked_leaving = false
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
      # The exit being taken or taken (POST /exit: :exit, :delete, :restart,
      # who asked), claimed under its own lock before #exit_request's slow
      # stop-all, and what that stop-all stopped.
      @exit_claim = WorkerExitClaim.new
      @grace_expired = false
      # The running turn has ended (its end event) and its after_turn hooks
      # run: a signal's grace waits for them (#signalled).
      @turn_ending = false
    end

    # Whether the session was empty as the worker left it, so the caller
    # deletes it once the lock is free (WorkerBoot.run_session_loop
    # checks again then).
    def discard? = @discard

    # Whether this worker runs a `chi scratch` session: deleted as it leaves
    # (WorkerBoot.run_session_loop).
    def scratch? = !!@session&.scratch

    # Whether delegate reports wait that an idle parent runs a turn for
    # (#wake_state): WorkerBoot.run_session_loop starts a new worker
    # for them after this one leaves. Reports the budget or a failure held
    # back wait for the next human input instead.
    def wake_due? = wake_state == :due

    # What a new session starts on (and /model resets to); nil before #run.
    attr_reader :default_model

    # @return [Symbol] :idle_exit, :exit_requested when a client asked it
    #   to exit (Bridge POST /exit), :restart when it asked for a restart
    #   (the caller starts a new worker), :stopped when the session was stopped
    #   (chi stop), :signal when a signal stopped it (WorkerSignals),
    #   :crashed when the loop raised (the session is marked errored),
    #   :scratch_left when a scratch session's terminal is gone (the caller
    #   deletes it); WorkerBoot.run_session_loop turns it into the exit
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

    # The step that stops what the user can stop (the reminders, the watched
    # tasks and the delegate children the exit ask lists). /exit's 2 uses
    # it; the web's Stop will too.
    attr_reader :hold_stop

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
      # A scratch worker's grace for its terminal's first stream counts from here.
      @started_at = monotonic_now
      # The wake turns' budget (delegate reports, attached context, peers), from now.
      @wakes = WorkerWakes.new(grace: WAKE_START_GRACE)
      # This worker holds the session now (a continue's starting marker held
      # off any other until it did), and a continue that died moving
      # delegates here left its intent: finish it.
      StartingMarker.clear(@session_id, state_dir: @state_dir)
      ChildMove.adopt(@session_id, state_dir: @state_dir)
      @session = Session.load(@session_id, state_dir: @state_dir)
      # A newer chi saved it: this worker keeps the fields it doesn't know
      # but runs the session without them (docs/sessions.md).
      if @session.newer_writer?
        unknown = @session.extra_fields.keys.join(",")
        Log.warn(:worker, "newer_writer", sid: @session_id, version: VERSION, written_by: @session.written_by,
                                          unknown_fields: (unknown unless unknown.empty?))
      end
      drop_dead_question
      # The running turn, on disk at its iteration boundaries.
      @checkpoint = TurnCheckpoint.new(session: @session, state_dir: @state_dir)
      # A restart's hand-off, checked before the Engine's build (its window
      # runs from the leave) and restored into it after.
      carried = take_carried_reminders
      @engine = build_engine
      # The Engine's event log, turn state, question desk and steer cut,
      # handed to the Bridge and the collaborators (read here, not in
      # #start_bridge, whose rescue would hide a missing one).
      @event_log = @engine.event_log
      @turn_state = @engine.turn_state
      @question_desk = @engine.question_desk
      @steer_cut = @engine.steer_cut
      restore_carried_reminders(carried)
      @config_restart_unsubscribe = ConfigFile.watch_restart_settings!(process: :worker) do |message|
        @event_log.announce(type: :hook_notice, hook: "config", text: message, level: :warn, between_turns: true)
      end
      prune_tombstones
      # What this worker did with each peer message (PeerReceipts, read once).
      @peer_receipts = PeerReceipts.new(session_id: @session_id, state_dir: @state_dir)
      settle_interrupted_turn
      settle_stale_status
      # Before the Bridge serves anything: a UI joining a resumed worker's
      # stream gets the session's history and status in its snapshot, not
      # an empty session until the first turn.
      @engine.session = @session
      # May this participant act (loop thread only): a turn as it starts,
      # the drain, the mid-turn stop, the Continue.
      @participant_gate = WorkerParticipantGate.new(engine: @engine, event_log: @event_log, session: @session, session_id: @session_id,
                                                    state_dir: @state_dir, session_dir: @session_dir,
                                                    hook: Engine::PARTICIPANTS_HOOK)
      # Who is in the review as the worker starts: no notice for them
      # (WorkerParticipantGate#watch announces the changes from here on).
      @participant_gate.watch
      # Input already waiting in the inbox starts the next turn at once, and
      # a command queued mid-turn (/thinking, /model, /llm-context) changes
      # what it starts with: no turn-end warm-up then.
      @engine.next_turn_waiting = lambda {
        !@command_queue.empty? || SessionInbox.find_new_input_files(@session_dir).any? || wake_due? || @task_wakes.due?
      }
      @turn_flow = TurnFlow.new(engine: @engine)
      # Its question's answer is queued as the matching /continue (the
      # Bridge exists by the time anyone answers).
      @continue_offer = ContinueOffer.new(engine: @engine, event_log: @event_log, turn_state: @turn_state,
                                          question_desk: @question_desk, turn_flow: @turn_flow, run_turn: method(:run_engine_turn),
                                          max_iterations: method(:max_iterations),
                                          participant_refused: @participant_gate.method(:refusal),
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
      @task_wakes = WorkerTaskWakes.new(engine: @engine, event_log: @event_log, session: @session, wakes: @wakes,
                                        awaiting_continue: -> { @turn_flow.awaiting_continue? },
                                        idle: -> { nothing_queued? && !@exit_claim.taken? },
                                        save: -> { save_or_log(:task_notes) { save_session } })
      @event_log.subscribe(observer: lambda { |event|
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
                                              project_root: @session.project_root, project_id: @session.project_id)
      # What comes in between turns, and how each kind is saved.
      @inbound = WorkerInbound.new(session: @session, state_dir: @state_dir, session_dir: @session_dir, engine: @engine,
                                   event_log: @event_log, turn_state: @turn_state, context_absorber: @context_absorber, wakes: @wakes,
                                   awaiting_continue: -> { @turn_flow.awaiting_continue? },
                                   stopped: -> { stopped_on_disk? },
                                   peer_registry: @engine.peer_registry, peer_receipts: @peer_receipts,
                                   mail_cap: -> { ToolOutputCut.max_chars(nil) },
                                   queue_command: lambda { |line, client_id, after_file, enqueued_id, author: nil|
                                     @bridge.queue_command(line, client_id: client_id, after_file: after_file,
                                                                 enqueued_id: enqueued_id, author: author)
                                   })
      # Notes its predecessor got after a continue that died before its
      # move, or from a writer that knew no head (ChildMove.adopt's twin).
      @inbound.adopt_notes
      # /model's default is the config's; the Engine started
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
      @bridge = start_bridge(engine: @engine, event_log: @event_log, turn_state: @turn_state, question_desk: @question_desk,
                             steer_cut: @steer_cut, state_dir: @state_dir, session_id: @session_id,
                             on_input: -> { @waker.wake },
                             on_command: method(:on_command),
                             on_exit_request: method(:exit_request),
                             # Decided again as it leaves (a note may still come in).
                             exit_discards: method(:empty_session?),
                             # What a stop-all /exit stopped, for its 200.
                             exit_stopped: method(:stopped_holds),
                             # chi web's Stop asks about these before TERMed-ing
                             # the worker (its own holds routes).
                             on_holds: -> { @idle_exit&.stoppable_holds },
                             on_holds_stop: -> { @hold_stop&.stop_all },
                             # `chi schedule tick` asks this before firing.
                             on_activity: method(:activity_snapshot))
      # What failed to load and what plugins showed as they loaded, now that
      # a UI can be there (a late one gets them in the snapshot).
      @engine.announce_load_events!
      announce_session_warnings
      @idle_exit = WorkerIdleExit.new(
        engine: @engine, turn_state: @turn_state, question_desk: @question_desk, bridge: @bridge,
        timeout_minutes: @idle_exit_minutes || config_idle_exit_minutes,
        input_pending: method(:input_pending?),
        awaiting_continue: -> { @turn_flow.awaiting_continue? },
        running_tasks: -> { Tools::TaskRuntime.running_created_in(@engine.messages_checkpoint) },
        # Only when a finish would wake the session (D3): with queue its end
        # is just a note, not worth keeping the worker up for. One that
        # finished since the pass looked holds too, until the next pass
        # wakes for it (#run_task_wake).
        watched_tasks: -> { TaskWatch.mode == "wake" ? @task_wakes.watch.holding : [] },
        watched_running: -> { TaskWatch.mode == "wake" ? @task_wakes.watch.running : [] },
        # Never a hold (a child is its own worker), but the exit ask lists
        # them so "stop them and exit" stops them too.
        delegates: method(:live_delegates)
      )
      @hold_stop = HoldStop.new(reminder_store: @engine.reminder_store, task_watch: @task_wakes.watch,
                                delegates: method(:live_delegates), state_dir: @state_dir)
    end

    # Start the in-process Bridge transport for this worker. The bridge is
    # the single live client transport, so every worker starts it. Bridge
    # creation happens *before* the loop so the capture observer is in place
    # for the whole session; the caller stops the returned instance on exit
    # (see #run's ensure).
    #
    # @return [Samagotchi::Bridge, nil] nil when the transport failed to start
    #   (the worker degrades: turns still flow through the input-dir loop, but
    #   there is no live SSE or in-process cancel/answer).
    # @param on_input [#call, nil] called after the Bridge queues a turn
    def start_bridge(engine:, event_log:, turn_state:, question_desk:, steer_cut:, state_dir:, session_id:, on_input: nil,
                     on_command: nil, on_exit_request: nil, exit_discards: nil, exit_stopped: nil, on_holds: nil,
                     on_holds_stop: nil, on_activity: nil)
      require_relative "bridge"
      Samagotchi::Bridge.new(
        engine: engine, event_log: event_log, turn_state: turn_state, question_desk: question_desk, steer_cut: steer_cut,
        state_dir: state_dir, session_id: session_id, input_format: SessionInbox::INPUT_FORMAT,
        on_input: on_input, on_command: on_command, on_exit_request: on_exit_request, exit_discards: exit_discards,
        exit_stopped: exit_stopped, on_holds: on_holds, on_holds_stop: on_holds_stop, on_activity: on_activity
      ).start
    rescue StandardError => e
      Log.error(:bridge, "start_failed", echo: "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}", sid: session_id, error: e.class.name)
      nil
    end

    def config_idle_exit_minutes
      Degrade.call(:config, "idle_exit_minutes_unreadable") { Samagotchi::Config.get("session.idle_exit_minutes") }
    end

    # What this worker is busy with right now, for GET /activity: the same
    # signals WorkerIdleExit#hold reads. A schedule never holds a worker up,
    # so +reminders+ and +tasks_holding+ are reported for the log but are not a
    # reason for a tick to skip a firing.
    # @return [Hash]
    def activity_snapshot
      {
        turn_running: @turn_state.running?,
        input_pending: input_pending?,
        awaiting_continue: @turn_flow.awaiting_continue?,
        open_streams: @bridge&.open_streams.to_i,
        reminders: @engine.reminder_store&.any? ? 1 : 0,
        tasks_holding: Degrade.call(:worker, "activity_tasks_unreadable") { @task_wakes&.watch&.holding&.size.to_i }
      }
    end

    # What runs beside the loop until it leaves.
    def start_background
      # Plugins' slow setup (chi.init: an MCP server's first start), in
      # the background, shown by the UIs; a turn waits only for the ones
      # that bring tools.
      @engine.start_init_tasks!
      # Toolkit suggestion's on mode: System 1's question, asked once with a
      # stand-in prompt so its prefix is cached before the first prompt.
      @engine.warm_toolkit_suggestion!
      # Attached context's commands, in the background; a new text wakes
      # the loop to absorb it. Not activity: the idle exit stops it.
      @context_poller = ContextPoller.new(session_id: @session_id, state_dir: @state_dir,
                                          project_root: @session.project_root, project_id: @session.project_id,
                                          cwd: @session.working_directory, on_change: -> { @waker.wake }).start
      @scratch_watch = start_scratch_watch if @session.scratch
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

      apply_block_fixes
      # Between turns, so the next turn (the first one too) sees them.
      # A change that asks to wake may start a turn here (C4), but not
      # ahead of an exit or restart a client asked for: it is a note then.
      @inbound.absorb_notes
      absorb_fresh_verdicts
      return if absorb_mail(hold: pass_hold)
      return if absorb_context(wake: nothing_queued? && !@exit_claim.taken?)

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
      return left(:scratch_left) if scratch_unattended? && !@turn_state.running? && leave_scratch
      return left(:idle_exit) if @idle_exit.due? && leave_idle

      leaving = @exit_claim.taken? && leave_on_request
      return left(leaving) if leaving

      @participant_gate.watch
      @waker.wait(idle_wait)
      nil
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
        apply_block_fixes
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
    # How long the lock stays held once #teardown marks it leaving (an upper
    # bound): the recap on leave is written by then (#left), what is left is
    # Bridge#stop's graces and ChildRing.await_wakes.
    TEARDOWN_LEAVE_WAIT = 10

    def teardown
      @scratch_watch&.kill
      @config_restart_unsubscribe&.call
      @context_poller&.stop
      drop_queued_commands
      @engine&.shutdown
      # Leaving before the Bridge closes: a client that finds its port shut
      # from here on reads Leaving (and waits for the lock), not Live.
      mark_leaving(wait: TEARDOWN_LEAVE_WAIT)
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
        # `chi scratch`: no memory_write, no delegates, approvals in memory.
        scratch: @session.scratch,
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
      # A pair turn stops mid-turn at its participant's cap.
      engine.participant_stop = ->(author) { @participant_gate.turn_stop(author) }
      # A block fix's result wakes the loop, which applies it between turns.
      engine.block_fix_ready = -> { waker.wake }
      engine.guardrail_state_dir = @state_dir if @state_dir
      engine.session_state_dir = @state_dir if @state_dir
      engine
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

    # The first prompt (spawn_session's): a delegate child's task, which is
    # its parent's. Its turn carries the id spawn_session gave it, so a
    # wait for it (--new --wait) names it, and its sender
    # (WorkerInbound#initial_origin).
    # A Verify fresh child's is a Verify turn on its claim (its verdict is
    # recorded and forwarded to the parent).
    def run_initial_prompt(prompt)
      @initial_turn = true
      fresh = @session.verify_fresh
      run_prompt(WorkerInbound::Prompt.new(text: prompt, origin: @inbound.initial_origin,
                                           anchors: { verify: fresh&.anchor }))
    ensure
      @initial_turn = false
    end

    def run_input_file(input_file)
      @inbound.take_input(input_file) { |prompt| run_prompt(prompt) }
    end

    # @param prompt [WorkerInbound::Prompt]
    def run_prompt(prompt)
      origin = fresh_origin(prompt.origin)
      # A participant's turn queued before their link ended or their cap was
      # reached doesn't start (chi web refuses new ones; this is the
      # worker's check).
      if (reason = @participant_gate.refusal(origin.author))
        return @participant_gate.refuse(origin, reason)
      end

      visitor = Visitor.of?(origin.client_id, @session)
      return refuse_visitor(origin) if visitor && !count_visitor

      # A candidate the prompt mentions is attached and fetched first, so
      # the absorb below brings its note into this turn.
      # Not for a visitor's prompt: only the owner's attaches (OwnerPrompt).
      unless visitor
        ContextCandidates.before_turn(session: @session, prompt: prompt.text, author: origin.author, state_dir: @state_dir,
                                      cancelled: -> { stopped_on_disk? })
      end
      # A first turn sees the context attached before it, and any turn the
      # background tasks that finished since the last look.
      absorb_context(before_turn: true)
      absorb_mail(hold: :before_turn)
      @task_wakes.absorb
      user_input(origin.client_id)
      @continue_offer.drop(origin)
      @turn_flow.before_prompt_turn
      # A visitor's opener is saved with its sender, which gives it its
      # header line (Steer::OPENER_HEADERS); the driver's and the owner's
      # keep their bytes.
      source = visitor ? { opener_source: origin.client_id } : {}
      run_engine_turn(prompt.text, origin: origin, max_iterations: max_iterations(prompt.no_interrupt),
                                   images: prompt.images, **source, **prompt.anchors.kwargs) do |result, error|
        if error
          # The Engine announced :turn_failed (with the error's one line).
          restore_failed_turn([[prompt.text, origin, prompt.images, prompt.anchors], *@merged_this_turn], error: error)
        else
          @continue_offer.after_turn(result, no_interrupt: prompt.no_interrupt)
        end
      end
      @participant_gate.refusal(origin.author)
    end

    # +origin+ as this session's turns run it: a participant's Verify fresh
    # child's are all theirs (VerifyFreshOrigin#origin_for).
    def fresh_origin(origin)
      fresh = @session&.verify_fresh
      fresh ? fresh.origin_for(origin) : TurnOrigin.of(origin)
    end

    def max_iterations(no_interrupt) = IterationLimit.for(no_interrupt: no_interrupt)

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
      origin = fresh_origin(turn_args[:origin])
      # Settled here: the checkpoint's prompt carries it from the start.
      turn_args = turn_args.merge(origin: origin, id: turn_args[:id] || SecureRandom.uuid)
      # The id its drain's merge records name (SessionInbox.mark_merged).
      @turn_enqueued_id = origin.enqueued_id
      verdicts_before = @session.verdicts.size
      @reporting_turn = reports_to_parent?(origin)
      # Who wrote the running turn (a participant's author, nil for the
      # owner's): its drain merges only their own lines (#pending_input_drain).
      @turn_author = origin.participant_author
      restores = @turn_flow.restores
      begin
        peer_turn_started(turn_args[:id])
        @checkpoint.begin_turn(prompt: prompt, turn_id: turn_args[:id], enqueued_id: origin.enqueued_id, author: turn_author_fields(origin),
                               source: turn_args[:opener_source], reply: ReplyFor.opener_fields(@session.messages, turn_args[:reply_for]))
        @session.status = Session::STATUS_RUNNING
        # A continue that moved this session to the chain's new link wrote
        # the new parent beside it (Session::PARENT_FILE): this turn's
        # status, its rings and every save from here on say so.
        @session.parent_id = Session.parent_override(@session_id, state_dir: @state_dir) || @session.parent_id
        save_session
        result = @engine.run_turn(@session, prompt, pending_input: pending_input_drain, input_waiting: method(:input_waiting?),
                                                    **turn_args)
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
      settle_peer_turn(turn_args[:id], result, error) { yield result, error }
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
      forward_fresh_verdicts(verdicts_before)
    end

    # WorkerInbound.save_or_log: a failed save between turns is logged.
    def save_or_log(at, &) = WorkerInbound.save_or_log(at, &)

    # Back to the conversation before the failed turn (so
    # failed prompts don't pile up as consecutive user messages), and each
    # prompt it took (its own and any merged into it) goes back to its
    # sender, who can send it again. The rollback and the announcements are
    # one step of the event log: a snapshot shows the failed turn's messages
    # or the restored ones, never the one without the other. A turn that
    # got somewhere stays instead (TurnFlow#prompt_turn_failed), with the
    # prompts it took: nothing goes back.
    # @param prompts [Array<Array(String, TurnOrigin|nil, Array|nil, TurnAnchors|nil)>]
    #   [prompt, origin, images, anchors] (a web client gets its image chips
    #   back, a Verify turn's claim, so sending it again still records a
    #   verdict, and a Revise turn's draft, so it still stacks)
    # @param error [Exception, nil] what failed: its one line stays in the
    #   conversation as a turn note
    # Not saved here: run_engine_turn saves after its block.
    def restore_failed_turn(prompts, error: nil)
      @event_log.synchronize do
        next if @turn_flow.prompt_turn_failed(error: error) == :kept

        prompts.each do |prompt, origin, images, anchors|
          restored = { type: :prompt_restored, prompt: prompt, origin: origin.wire }
          restored[:images] = images unless Array(images).empty?
          restored.merge!(anchors.to_h) if anchors
          @event_log.announce(restored)
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
        # A participant's turn takes only their own lines: the owner's and
        # anyone else's (the Bridge queues them, this covers a file it didn't
        # see) run as their own turns after it, never inside its boundary;
        # and the owner's turn takes no participant's (SessionInbox.turn_end_data?).
        files = SessionInbox.find_new_input_files(@session_dir).sort
                            .reject { |input_file| SessionInbox.waits_for_turn_end?(input_file, running_author: @turn_author) }
        merged = files.filter_map do |input_file|
          claimed_file = SessionInbox.claim_input_file(input_file)
          next unless claimed_file

          begin
            input = SessionInbox.read_input(claimed_file)
            enqueued_id = input.origin.enqueued_id
            if SessionInbox.input_taken?(@session_dir, @session, enqueued_id) || !@turn_state.claim_enqueued_id(enqueued_id)
              Log.info(:worker, "duplicate_input_dropped", enqueued_id: enqueued_id)
              next
            end
            begin
              # A participant's line gets the checks their queued turn gets at
              # its start (WorkerParticipantGate#refusal: the link, the cap): refused,
              # it is taken off as that turn would be, and never merged.
              if (author = input.origin.participant_author) && (reason = @participant_gate.refusal(author))
                @participant_gate.refuse(input.origin, reason)
                next
              end
              prompt = input.prompt.to_s.strip
              # Which turn took it, on disk before its file goes (a wait for
              # it reads this, not an inference: ReplyWait::Poll#follow_merge).
              SessionInbox.mark_merged(@session_dir, enqueued_id, into: @turn_enqueued_id) unless prompt.empty?
              prompt.empty? ? nil : [prompt, input.origin]
            ensure
              @turn_state.finish_enqueued_id(enqueued_id)
            end
          ensure
            FileUtils.rm_f(claimed_file)
          end
        end
        merged.each { |_prompt, origin| user_input(origin.client_id) }
        # Delegate children's reports: never handed back on a failure
        # (their rings stay for the next turn), so not in @merged_this_turn.
        reports, mark = take_child_reports
        unless merged.empty? && reports.empty?
          @event_log.announce(type: :input_merged, count: merged.size + reports.size,
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

    # Whether a person's message waits that the next boundary merges
    # (SessionInbox.steer_waiting?): a running task_wait ends on it. In a
    # participant's turn only their own.
    def input_waiting?
      SessionInbox.steer_waiting?(@session_dir, running_author: @turn_author)
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

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
  end
end
