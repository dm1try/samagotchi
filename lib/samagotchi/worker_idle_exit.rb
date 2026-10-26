# frozen_string_literal: true

module Samagotchi
  # When a background session worker nobody uses should exit. The session is
  # saved after every turn, so the next send wakes a new worker with the
  # conversation intact; what lives only in memory (metrics, the Bridge's
  # event ring, the last recap) is lost.
  #
  # The worker stays up while any of these holds:
  # * a turn runs, or input is queued for one;
  # * a client holds the Bridge's stream (an attached TUI, even an idle one,
  #   or a web tab);
  # * a reminder is registered. Reminders live only in the Engine and repeat
  #   until the agent cancels them, so an exit would drop them for good;
  # * a continue offer waits for an answer; it too lives only in memory;
  # * a background task the worker watches for a finish wake (TaskWatch)
  #   still runs, or finished and waits for the next pass's wake: its end
  #   would go unnoticed after an exit (D3);
  # * less than the timeout has passed since the worker started, the Engine's
  #   last activity, or the last client request or disconnect.
  #
  # A client can also ask the worker to exit now (`/exit` in the attached
  # TUI, Bridge POST /exit): #hold_for_request applies the same rules without
  # the timeout and leaves out the asking client's own stream. A restart
  # (POST /exit restart: true) has its own rules, #hold_for_restart.
  class WorkerIdleExit
    # What keeps the worker up when a client asks it to exit (Worker#exit_request,
    # the Bridge's 409): +reason+, a #hold_for_request (or #hold_for_restart)
    # Symbol, or :starting before this policy exists; for :background_tasks
    # the watched tasks still running ({id:, command:, age_seconds:}) and a
    # +hint+ on stopping them; +holds+ what the user can stop from the exit
    # ask (#StoppableHold), empty when the reason is something they can't.
    Hold = Data.define(:reason, :tasks, :hint, :holds) do
      def initialize(reason:, tasks: nil, hint: nil, holds: []) = super

      # Held only by things the user can stop: /exit asks what to do with them
      # rather than refusing.
      def ask? = !holds.empty?
    end

    # One kind of hold the exit ask offers to stop: +kind+ (:reminders,
    # :background_tasks or :delegates) and its +items+ (#HoldItem). The 409's
    # +holds+ is this in JSON: `{kind:, items: [{id:, label:, detail:}]}`.
    StoppableHold = Data.define(:kind, :items)

    # One entry of a hold: +id+ (a reminder's name, a task id, a child session
    # id), +label+ (the command, the child's title) and +detail+ ("every 20m",
    # "2m", "running a turn").
    HoldItem = Data.define(:id, :label, :detail)

    # @param engine [Engine] #turn_running?, #last_activity_at, #reminder_store
    # @param bridge [Bridge, nil] #open_streams, #last_client_activity_at; nil
    #   when the worker's Bridge failed to start
    # @param timeout_minutes [Numeric, nil] 0 or nil: never exit
    # @param input_pending [#call] true while input files wait
    # @param awaiting_continue [#call] true while a continue offer waits
    # @param running_tasks [#call] the background tasks this conversation
    #   started that still run (Tools::TaskRuntime.running_created_in)
    # @param watched_tasks [#call] the ones a finish wake would wake for,
    #   running or not yet taken (TaskWatch#holding): they hold the idle exit
    # @param watched_running [#call] those of them still running
    #   (TaskWatch#running): they hold /exit (one that finished is a note
    #   as the worker leaves)
    # @param delegates [#call] the delegate children this session has running
    #   or with a live worker (ChildrenStatus::Child): they never hold the
    #   exit, but the exit ask lists them so "stop them" stops them too
    # @param clock [#call] monotonic seconds, the Engine's and Bridge's clock
    def initialize(engine:, bridge:, timeout_minutes:, input_pending:, awaiting_continue: -> { false },
                   running_tasks: -> { [] }, watched_tasks: -> { [] }, watched_running: -> { [] },
                   delegates: -> { [] }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @engine = engine
      @bridge = bridge
      @timeout = timeout_minutes.to_f * 60
      @input_pending = input_pending
      @awaiting_continue = awaiting_continue
      @running_tasks = running_tasks
      @watched_tasks = watched_tasks
      @watched_running = watched_running
      @delegates = delegates
      @clock = clock
      @started_at = clock.call
    end

    # @return [Boolean] whether the worker should exit now
    def due?
      hold.nil?
    end

    # What keeps the worker up, or nil when nothing does.
    # @return [Symbol, nil] :disabled, :turn_running, :input_queued,
    #   :continue_offered, :client_connected, :reminders, :background_tasks
    #   or :recent_activity
    def hold
      return :disabled unless @timeout.positive?
      return :turn_running if @engine.turn_running?
      return :input_queued if @input_pending.call
      return :continue_offered if @awaiting_continue.call
      return :client_connected if @bridge && @bridge.open_streams.positive?
      return :reminders if @engine.reminder_store&.any?
      return :background_tasks if @watched_tasks.call.any?
      return :recent_activity if idle_seconds < @timeout

      nil
    end

    # What keeps the worker up when a client asks it to exit now, or nil
    # when nothing does. The timeout doesn't apply, even 0 ("never idle
    # out"): the request is explicit.
    # @param requester [String, nil] the asking client's id; its own streams
    #   don't hold
    # @param streams [Boolean] false: other clients' streams don't hold
    #   either (the last check before leaving, when the asker's stream may
    #   still be open, untagged)
    # @return [Symbol, nil] :turn_running, :input_queued, :continue_offered,
    #   :client_connected, :reminders or :background_tasks
    def hold_for_request(requester:, streams: true) = request_hold(requester: requester, streams: streams)&.reason

    # What the user could stop in this worker right now, whatever else keeps
    # it up: its reminders, the watched background tasks still running, and
    # (for a UI that asks about them, +include_delegates+) the delegate
    # children with a live worker. #request_hold's +holds+ is this, and the
    # web's Stop asks with it before TERMed-ing the worker — a turn running
    # or another UI attached does not hide it, since Stop cancels the turn
    # anyway (docs/sessions.md, "Stopping a worker").
    # @return [Array<StoppableHold>]
    def stoppable_holds(running: @watched_running.call, include_delegates: true)
      holds = []
      reminders = reminder_items
      tasks = running.map do |task|
        HoldItem.new(id: task.id, label: task.command, detail: age_words(task.age_seconds))
      end
      children = include_delegates ? delegate_items : []

      holds << StoppableHold.new(kind: :reminders, items: reminders) if reminders.any?
      holds << StoppableHold.new(kind: :background_tasks, items: tasks) if tasks.any?
      holds << StoppableHold.new(kind: :delegates, items: children) if children.any?
      holds
    end

    # #hold_for_request as a Hold: for :background_tasks, the watched tasks
    # still running, read once (TaskWatch#running looks at each task's
    # process), with +hint+. +ask+: the client will ask the user about what
    # still runs (an attached terminal's plain `/exit`), so the delegate
    # children this session has running or with a live worker are listed too;
    # they are never a hold on their own, so a request without +ask: true
    # (an exit that deletes the session, the worker's last look before
    # leaving) ignores them.
    # @return [Hold, nil]
    def request_hold(requester:, streams: true, hint: nil, ask: false)
      reason = if @engine.turn_running? then :turn_running
               elsif @input_pending.call then :input_queued
               elsif @awaiting_continue.call then :continue_offered
               elsif streams && @bridge && @bridge.open_streams_except(requester).positive? then :client_connected
               end
      return Hold.new(reason: reason) if reason

      running = @watched_running.call
      holds = stoppable_holds(running: running, include_delegates: ask)
      return nil if holds.empty?

      Hold.new(reason: holds.first.kind, tasks: running.map(&:to_h), hint: hint, holds: holds)
    end

    # What keeps the worker from restarting now (a client asked: POST /exit
    # restart: true), or nil. A restart drops what lives only in this
    # process, so whatever would be lost or cut holds it: a question or
    # approval waiting (a turn's), a /btw (or another anytime command)
    # running, a delegate's approval relay this worker still answers for,
    # background tasks this conversation started (their output and end are
    # this worker's to report). Clients' streams don't hold: a web tab
    # reconnects on the new worker's bridge_up, an attached terminal finds
    # the new worker's Bridge.
    # @return [Symbol, nil] :turn_running, :input_queued, :continue_offered,
    #   :question_pending, :reminders, :command_running, :relays_open or
    #   :background_tasks
    def hold_for_restart
      return :turn_running if @engine.turn_running?
      return :input_queued if @input_pending.call
      return :continue_offered if @awaiting_continue.call
      return :question_pending if @engine.pending_question
      return :reminders if @engine.reminder_store&.any?
      return :command_running if @engine.anytime_running?
      return :relays_open if @engine.relay_desk.active?
      return :background_tasks if @running_tasks.call.any?

      nil
    end

    # @return [Float] seconds since the latest activity of any kind
    def idle_seconds
      last = [@started_at, @engine.last_activity_at, @bridge&.last_client_activity_at].compact.max
      @clock.call - last
    end

    private

    # One item per reminder the Engine holds. Every reminder ReminderStore
    # registers is periodic (interval_minutes, 1..1440), so the detail is its
    # schedule — "every 20m", "every 1h" for a whole number of hours — plus
    # ", due now" when its next fire has already come. An entry written
    # without an interval (a store from another chi, a hand-edited one) has no
    # detail: the label alone.
    def reminder_items
      store = @engine.reminder_store
      return [] unless store

      store.reminders.values.map do |reminder|
        HoldItem.new(id: reminder[:name], label: reminder[:name].to_s, detail: schedule_words(reminder))
      end
    end

    def schedule_words(reminder)
      minutes = Integer(reminder[:interval_minutes], exception: false)
      return nil if minutes.nil? || minutes <= 0

      words = (minutes % 60).zero? ? "every #{minutes / 60}h" : "every #{minutes}m"
      next_fire = reminder[:next_fire_at]
      words = "#{words}, due now" if next_fire && @clock.call >= next_fire
      words
    end

    # One item per delegate child still running or with a live worker.
    def delegate_items
      @delegates.call.map do |child|
        HoldItem.new(id: child.id, label: child.title.to_s, detail: child_state_words(child))
      end
    end

    # What a child is doing, as the ask says it. #live_delegates takes only
    # ones running a turn or with a worker of their own.
    def child_state_words(child)
      case child.state
      when "running" then "running a turn"
      when "waiting" then "waiting for an answer"
      else "a live worker"
      end
    end

    # How long a task has been running, as the ask words it ("2m", "42s");
    # nil when its record has no start time.
    def age_words(seconds)
      return nil if seconds.nil?
      return "#{seconds / 3600}h" if seconds >= 3600
      return "#{seconds / 60}m" if seconds >= 60

      "#{seconds}s"
    end
  end
end
