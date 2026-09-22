# frozen_string_literal: true

require "monitor"

module Samagotchi
  # SessionObserver is a small persistent subscriber registry.
  #
  # Unlike the turn-scoped `Engine#run_turn` `on_event:` sink (passed once per
  # turn and gone when the turn ends), a subscriber registered here keeps
  # receiving events across every `run_turn` call on the same Engine instance.
  #
  # Each delivery carries a locally-monotonic `event_seq` so a subscriber can
  # track ordering and how far behind it is. Subscribers are error-isolated:
  # a subscriber that raises does not stop other subscribers from receiving the
  # same event, and does not break the running turn.
  #
  # Documented event vocabulary (subscribers match on `:type`):
  #   * turn_started / turn_completed / turn_canceled / turn_failed — turn
  #     boundaries (turn_completed also carries a JSON-safe `turn_summary:`)
  #   * generation_* / tool_call_* / tool_dispatch_* — raw kernel-loop events
  #   * session_activity — an activity tick was recorded (see Engine#record_activity)
  #   * recap_ready — an idle session-recap finished generating
  #     (`recap:` prose, `generation:` id). Purely additive: it never mutates
  #     session.messages; each UI renders it (or not) however it likes.
  class SessionObserver
    # Handle returned by #subscribe. Holds the observer reference and carries
    # #unsubscribe so a caller can deregister without keeping the registry.
    class SubscribedObserver
      # @return [#call] the wrapped observer
      attr_reader :observer

      def initialize(observer, registry)
        @observer = observer
        @registry = registry
      end

      # @return [Boolean, nil] true when this handle has unsubscribed, otherwise nil
      def unsubscribed?
        @unsubscribed
      end

      # Deregister this subscriber. Idempotent and safe to call multiple times.
      # @return [Boolean] true if it was removed, false if already gone
      def unsubscribe
        return false if @unsubscribed

        @unsubscribed = true
        @registry&.unsubscribe(handle: self)
      end
    end

    def initialize
      @mutex = Monitor.new
      @observers = [] # Array<SubscribedObserver>
      @seq = 0
    end

    # Register a persistent subscriber (any object responding to #call(event)).
    # @param observer [#call] the sink
    # @return [SubscribedObserver] handle usable with #unsubscribe
    def subscribe(observer:)
      handle = SubscribedObserver.new(observer, self)
      @mutex.synchronize { @observers << handle }
      handle
    end

    # Remove a previously-registered subscriber.
    # @param handle [SubscribedObserver, nil]
    # @return [Boolean] true if it was removed, false otherwise (nil/unknown/
    #   already-unsubscribed never raises)
    def unsubscribe(handle:)
      return false unless handle.is_a?(SubscribedObserver)
      @mutex.synchronize { !!@observers.delete(handle) }
    end

    # Assign a monotonic event_seq and fan out to every current subscriber.
    # @param event [Hash] the raw emitted event (delivered to observers as a
    #   copy with `event_seq:` merged in; never mutated in place)
    # @return [void]
    def notify(event)
      # Number AND deliver under one lock. Events arrive from several threads
      # (turn, idle scheduler, bridge HTTP); delivering outside the lock let
      # seq N reach a subscriber after N+1 (the SSE writer then dropped it as
      # below its high-water mark) and let a numbered event fall between a
      # new connection's replay snapshot and its live queue. Subscribers must
      # stay non-blocking (enqueue-only), so holding the lock is cheap. The
      # Monitor is reentrant, so a subscriber that emits on the same thread
      # does not deadlock.
      @mutex.synchronize do
        payload = event.merge(event_seq: @seq += 1)

        @observers.dup.each do |handle|
          next if handle.unsubscribed?

          begin
            handle.observer.call(payload)
          rescue StandardError
            # Error-isolate: a throwing subscriber must not stop others or break
            # the running turn.
          end
        end
      end
    end

    # @return [Integer] total events emitted so far (Engine-local sequence)
    def event_count
      @mutex.synchronize { @seq }
    end

    # Run the block while no event is being numbered or delivered, so it sees
    # (and can change) state consistently with the event log. Reentrant: the
    # block may notify. Keep it short; every emitter waits for it.
    def synchronize(&block)
      @mutex.synchronize(&block)
    end
  end
end
