# frozen_string_literal: true

require_relative "../memory_orphans"
require_relative "../project_id_clash"
require_relative "../event_fanout"
require_relative "../memory_paths"
require_relative "../working_set"

module Samagotchi
  class Engine
    # The event log: persistent observers, #announce (the log's ANNOUNCEABLE_EVENTS),
    # the event lock, held announcements, the load events, and the stream
    # and emit helpers (EventFanout's, forwarded). Writes
    # @guardrail_failures_announced; reads @event_log, @event_fanout,
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
        @event_log.subscribe(observer: observer)
      end

      # Unsubscribe a previously-registered observer.
      # @param handle [Samagotchi::SessionObserver::SubscribedObserver]
      # @return [Boolean] whether the observer was removed (nil/unknown never raises)
      def unsubscribe(handle:)
        @event_log.unsubscribe(handle: handle)
      end

      # @return [Integer] total engine events emitted so far (locally monotonic)
      def event_count
        @event_log.event_count
      end

      # Put a transport-level event into the ordered event log
      # (SessionObserver#announce, which checks the type).
      # @param event [Hash] with :type in SessionObserver::ANNOUNCEABLE_EVENTS
      # @raise [ArgumentError] for any other type
      def announce(event)
        @event_log.announce(event)
      end

      # Run the block with the event log held: no event is numbered or
      # delivered meanwhile, and events the block emits keep their order.
      def synchronize_events(&)
        @event_log.synchronize(&)
      end

      def reserve_enqueued_id(id) = @turn_state.reserve_enqueued_id(id)

      def claim_enqueued_id(id) = @turn_state.claim_enqueued_id(id)

      def finish_enqueued_id(id) = @turn_state.finish_enqueued_id(id)

      def forget_enqueued_id(id) = @turn_state.forget_enqueued_id(id)

      def drop_enqueued_id(id) = @turn_state.drop_enqueued_id(id)

      def enqueued_id?(id) = @turn_state.enqueued_id?(id)

      # The working set's :working_set_updated, announced between turns
      # (after a command changed what the next request sends), when it
      # differs from the last one emitted (#emit_working_set). Under the
      # event lock, so it is ordered with the change's own events.
      def announce_working_set(session = @session)
        return unless session

        synchronize_events { emit_working_set(nil, session, session.messages) }
      end

      # The working set the session would announce for +conversation+ under
      # the next turn's strategy.
      def working_set_snapshot(session = @session, conversation = session&.messages)
        return unless session && conversation

        WorkingSet.build(conversation, cwd: session.working_directory, strategy: working_set_strategy,
                         pins: session.working_set_pins)
      end

      # The conversation the working set is built from now: the running
      # turn's view as of its last request (EventFanout#turn_view), else a
      # copy of the session's messages (a starting turn shares their entries
      # and writes them in place: Engine#turn_messages), taken under the
      # event lock as #working_set_snapshot's callers read them. nil with no
      # session.
      # @return [EventFanout::TurnView, nil]
      def working_set_view
        @event_fanout.turn_view || synchronize_events do
          session = @session
          if session
            messages = clone_messages(session.messages)
            EventFanout::TurnView.new(turn_id: nil, conversation: messages, at: messages.size,
                                      strategy: working_set_strategy, cwd: session.working_directory)
          end
        end
      end

      # What the model has of one item (WorkingSet.timeline_of's to_h), from
      # #working_set_view: the Bridge's GET working_set/item. +now+ (a
      # memory): its text now (WorkingSet.memory_now). +latest+: only what
      # the peek draws (Timeline#peek_h). +at+ is the view's size, +running+
      # whether it is a running turn's (+turn_id+ then names it). nil with
      # no session.
      # @return [Hash, nil]
      def working_set_item(kind:, key:, now: false, latest: false)
        view = working_set_view or return nil

        conversation = view.conversation
        strategy = view.strategy
        cwd = view.cwd
        timeline = WorkingSet.timeline_of(conversation, kind: kind, key: key, strategy: strategy, cwd: cwd)
        body = latest ? timeline.peek_h : timeline.to_h
        if now && kind == WorkingSet::MEMORY
          body[:now] = WorkingSet.memory_now(conversation, key: key, strategy: strategy, cwd: cwd,
                                             root: MemoryPaths.system_dir)&.to_h
        end
        body[:turn_id] = view.turn_id if view.turn_id
        body.merge(at: view.at, running: view.turn_id ? true : turn_running?)
      end

      # ── Load events ───────────────────────────────────────────────────────

      # Announce what failed to load and what plugins showed while loading,
      # once, as soon as the owner can show it (the worker's Bridge is up):
      # the guardrail and plugin warnings, an orphaned
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
          memory_load_warnings.each { |event| announce(event) }
          @extension_load.held_events.each do |event|
            announce(event[:type] == :card ? event.merge(in_turn: false) : event.merge(between_turns: true))
          end
        end
        nil
      end

      # The session-start memory warnings (label "memory"), for both load
      # announcements (a worker's, a one-shot's first turn): an orphaned
      # project memory folder (MemoryOrphans), a copied project sharing its
      # id (ProjectIdClash, which also claims the id folder for this root).
      # @return [Array<Hash>] the :guardrail_warning events
      def memory_load_warnings
        [MemoryOrphans.message, ProjectIdClash.check&.message].compact.map do |message|
          { type: :guardrail_warning, message: message, label: "memory" }
        end
      end
      private :memory_load_warnings

      # Run the block holding back the cards and between-turns notices it
      # announces on this thread, so the caller announces them after its own
      # event (a worker's command: its command_ran first, so a UI prints the
      # command's output before its cards).
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
