# frozen_string_literal: true

module Samagotchi
  class Engine
    # The event log: persistent observers, #announce (ANNOUNCEABLE_EVENTS),
    # the event lock, held announcements, the load events, and the stream
    # and emit helpers (EventFanout's, forwarded). Writes
    # @guardrail_failures_announced; reads @session_observer, @event_fanout,
    # @extension_load, @guardrail_failures, @plugin_failures.
    module EventsPart
      # Subscribe a persistent observer to engine events.
      #
      # Unlike the turn-scoped `on_event:` sink, a subscribed observer keeps
      # receiving events across every `run_turn` call on this Engine. Each
      # delivery carries a locally-monotonic `event_seq`. The returned handle can
      # be used to unsubscribe later.
      # @param observer [#call] receives event hashes (with `event_seq:` merged in)
      # @return [Samagotchi::SessionObserver::SubscribedObserver] handle to unsubscribe
      def subscribe(observer:)
        @session_observer.subscribe(observer: observer)
      end

      # Unsubscribe a previously-registered observer.
      # @param handle [Samagotchi::SessionObserver::SubscribedObserver]
      # @return [Boolean] whether the observer was removed (nil/unknown never raises)
      def unsubscribe(handle:)
        @session_observer.unsubscribe(handle: handle)
      end

      # @return [Integer] total engine events emitted so far (locally monotonic)
      def event_count
        @session_observer.event_count
      end

      # Put a transport-level event into the ordered event log. Unlike turn
      # events it reaches only persistent observers (no turn sink, no memory
      # capture).
      # @param event [Hash] with :type in ANNOUNCEABLE_EVENTS
      # @raise [ArgumentError] for any other type
      def announce(event)
        unless ANNOUNCEABLE_EVENTS.include?(event[:type])
          raise ArgumentError, "cannot announce #{event[:type].inspect} (allowed: #{ANNOUNCEABLE_EVENTS.join(", ")})"
        end

        @session_observer.notify(event)
      end

      # Run the block with the event log held: no event is numbered or
      # delivered meanwhile, and events the block emits keep their order.
      def synchronize_events(&)
        @session_observer.synchronize(&)
      end

      # The working set's :working_set_updated, announced between turns
      # (after a command changed what the next request sends), when it
      # differs from the last one emitted (#emit_working_set). Under the
      # event lock, so it is ordered with the change's own events.
      def announce_working_set(session = @session)
        return unless session

        synchronize_events { emit_working_set(nil, session, session.messages) }
      end

      # ── Load events ───────────────────────────────────────────────────────

      # Announce what failed to load and what plugins showed while loading,
      # once, as soon as the owner can show it (the worker's Bridge is up, the
      # REPL renders events): the guardrail and plugin warnings, an orphaned
      # project memory folder (label: "memory", MemoryOrphans), then the
      # held notices (between_turns) and cards (in_turn: false, so late
      # joiners get them). Without this call the first turn announces them
      # (#announce_guardrail_failures).
      def announce_load_events!
        synchronize_events do
          next if @guardrail_failures_announced

          @guardrail_failures_announced = true
          message = @guardrail_failures.message
          announce({ type: :guardrail_warning, message: message }) if message
          plugins = @plugin_failures.message
          announce({ type: :guardrail_warning, message: plugins, label: "plugins" }) if plugins
          memory = MemoryOrphans.message
          announce({ type: :guardrail_warning, message: memory, label: "memory" }) if memory
          @extension_load.held_events.each do |event|
            announce(event[:type] == :card ? event.merge(in_turn: false) : event.merge(between_turns: true))
          end
        end
        nil
      end

      # Run the block holding back the cards and between-turns notices it
      # announces on this thread, so the caller announces them after its own
      # event (a worker's command: its command_ran first, as the REPL prints
      # the command's output before its cards).
      # @return [Array(Object, Array<Hash>)] the block's value and the held events
      def holding_announcements
        key = :"samagotchi_held_#{object_id}"
        outer = Thread.current[key]
        Thread.current[key] = []
        value = yield
        [value, Thread.current[key]]
      ensure
        Thread.current[key] = outer
      end

      # Announce +event+ now, or keep it for #holding_announcements' caller.
      def announce_or_hold(event)
        held = Thread.current[:"samagotchi_held_#{object_id}"]
        held ? held << event : announce(event)
      end
      private :announce_or_hold

      private

      # ── Event helpers ──────────────────────────────────────────────────────────

      # The stream handler, the working set and the event fan-out are
      # EventFanout's (#build_event_fanout); these forward to it.
      def build_stream_event_handler(...) = @event_fanout.build_stream_event_handler(...)
      def emit_working_set(...) = @event_fanout.emit_working_set(...)
      private :emit_working_set
      def working_set_llm_context = @event_fanout.working_set_llm_context
      private :working_set_llm_context
      def with_generation_report(event) = @event_fanout.with_generation_report(event)
      private :with_generation_report
      def stream_watch(cancel_controller) = @event_fanout.stream_watch(cancel_controller)
      private :stream_watch
      def emit_event(on_event, event) = @event_fanout.emit_event(on_event, event)
    end
  end
end
