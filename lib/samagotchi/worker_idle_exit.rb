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
  # * less than the timeout has passed since the worker started, the Engine's
  #   last activity, or the last client request or disconnect.
  #
  # A client can also ask the worker to exit now (`/exit` in the attached
  # TUI, Bridge POST /exit): #hold_for_request applies the same rules without
  # the timeout and leaves out the asking client's own stream. A restart
  # (POST /exit restart: true) has its own rules, #hold_for_restart.
  class WorkerIdleExit
    # @param engine [Engine] #turn_running?, #last_activity_at, #reminder_store
    # @param bridge [Bridge, nil] #open_streams, #last_client_activity_at; nil
    #   when the worker's Bridge failed to start
    # @param timeout_minutes [Numeric, nil] 0 or nil: never exit
    # @param input_pending [#call] true while input files wait
    # @param awaiting_continue [#call] true while a continue offer waits
    # @param running_tasks [#call] the background tasks this conversation
    #   started that still run (Tools::TaskRuntime.running_created_in)
    # @param clock [#call] monotonic seconds, the Engine's and Bridge's clock
    def initialize(engine:, bridge:, timeout_minutes:, input_pending:, awaiting_continue: -> { false },
                   running_tasks: -> { [] }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @engine = engine
      @bridge = bridge
      @timeout = timeout_minutes.to_f * 60
      @input_pending = input_pending
      @awaiting_continue = awaiting_continue
      @running_tasks = running_tasks
      @clock = clock
      @started_at = clock.call
    end

    # @return [Boolean] whether the worker should exit now
    def due?
      hold.nil?
    end

    # What keeps the worker up, or nil when nothing does.
    # @return [Symbol, nil] :disabled, :turn_running, :input_queued,
    #   :continue_offered, :client_connected, :reminders or :recent_activity
    def hold
      return :disabled unless @timeout.positive?
      return :turn_running if @engine.turn_running?
      return :input_queued if @input_pending.call
      return :continue_offered if @awaiting_continue.call
      return :client_connected if @bridge && @bridge.open_streams.positive?
      return :reminders if @engine.reminder_store&.any?
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
    #   :client_connected or :reminders
    def hold_for_request(requester:, streams: true)
      return :turn_running if @engine.turn_running?
      return :input_queued if @input_pending.call
      return :continue_offered if @awaiting_continue.call
      return :client_connected if streams && @bridge && @bridge.open_streams_except(requester).positive?
      return :reminders if @engine.reminder_store&.any?

      nil
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
  end
end
