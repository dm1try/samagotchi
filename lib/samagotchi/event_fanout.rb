# frozen_string_literal: true

require_relative "hooks"
require_relative "log"
require_relative "steer_cut"
require_relative "working_set"

module Samagotchi
  # How one of an Engine's events reaches the turn's sink and the persistent
  # observers (#emit_event: the used-memories capture, the isolated sink
  # call, the observer notify, the follow-up :used_memories_updated), the
  # stream handler that wraps each raw loop event (#build_stream_event_handler:
  # SteerCut, ThinkingNotices, the StreamWatch, the generation report, the
  # working set at each request), and the working set's dedupe
  # (#emit_working_set).
  #
  # What it needs from the Engine comes through lookups, read at call time;
  # the Engine forwards each method here. It takes no lock: the observers'
  # notify takes the event lock, as before. #announce_or_hold stays the
  # Engine's: its thread-local is keyed on the Engine.
  class EventFanout
    # @param observer          [#call] → SessionObserver
    # @param used_memories     [#call] → UsedMemories
    # @param muted             [#call] → Array<String>, the muted memory names
    # @param steer_cut         [#call] → SteerCut
    # @param thinking_notices  [#call] → ThinkingNotices
    # @param metrics           [#call] → SessionMetrics
    # @param hooks             [#call] → Hooks::Registry
    # @param kernel            [#call] → KernelLoop
    # @param model_settings    [#call] → SessionModelSettings
    # @param session           [#call] → Session, nil
    # @param live_conversation [#call] → Array<Hash>, the running turn's conversation
    # @param used_memory_names [#call] → Array<String>
    # @param served_expected_by [#call] (served) → the host expecting the served model
    # @param working_set_strategy [#call] → the strategy the working set is built under
    # @param turn_running      [#call] → Boolean
    # @param announce_or_hold  [#call] (event) → announces the event, or holds it
    def initialize(observer:, used_memories:, muted:, steer_cut:, thinking_notices:, metrics:, hooks:, kernel:,
                   model_settings:, session:, live_conversation:, used_memory_names:, served_expected_by:,
                   working_set_strategy:, turn_running:, announce_or_hold:)
      @observer = observer
      @used_memories = used_memories
      @muted = muted
      @steer_cut = steer_cut
      @thinking_notices = thinking_notices
      @metrics = metrics
      @hooks = hooks
      @kernel = kernel
      @model_settings = model_settings
      @session = session
      @live_conversation = live_conversation
      @used_memory_names = used_memory_names
      @served_expected_by = served_expected_by
      @working_set_strategy = working_set_strategy
      @turn_running = turn_running
      @announce_or_hold = announce_or_hold
      @working_set_emitted = nil
    end
    # rubocop:enable Metrics/ParameterLists

    # Always return a handler so raw kernel loop events reach the persistent
    # SessionObserver (and thus the analytics collector) even when there is no
    # turn-scoped +on_event+ sink (e.g. the -p/--resume paths and
    # SessionManager background workers). emit_event tolerates a nil on_event by
    # only notifying the observer.
    # Wrap a raw kernel stream event and fan it out to the turn sink + observers.
    #
    # Each :generation_chunk comes split already, by the loop that streamed it:
    # besides the raw `content` (left untouched — the TUI thinking spinner,
    # analytics, and Bridge replay rely on it) it carries
    #   * :text     — visible prose (thinking AND tool_call blocks removed)
    #   * :thinking — thinking-only content
    # KernelLoop splits a native stream with a ThoughtStreamSplitter per
    # generation (every profile, Gemma's thought channel included); the chat
    # loop gets reasoning apart from the answer. The web routes on those
    # fields (chunk_router.js).
    #
    # With a :generation_progress hook registered, a Hooks::StreamWatch gets
    # each chunk's thinking and text after the UIs had it.
    #
    # +model_ref+: the turn's model (#generation_model_ref), added to each
    # :generation_started as `model_ref:` (both loops send through here).
    def build_stream_event_handler(on_event, cancel_controller: nil, model_ref: nil)
      watch = stream_watch(cancel_controller)
      proc do |event|
        progress = SteerCut.lanes(event) if event[:type] == :generation_chunk
        steer_cut.observe(event, progress)
        case event[:type]
        when :generation_started
          event = event.merge(model_ref: model_ref) if model_ref
          thinking_notices.generation_started
          watch&.started(event[:iteration])
        when :generation_retrying
          # A dropped stream's step asked again: it streams from the start.
          if event[:restarted]
            thinking_notices.generation_started
            watch&.started(event[:iteration], restarted: true)
          end
        when :generation_chunk then thinking_notices.note_thought(progress[:thinking])
        end
        # The chat loop asked again without the thinking fields or the
        # reasoning sent back: a notice, not an event of its own.
        next thinking_notices.thinking_refused(event) if event[:type] == :thinking_refused
        next thinking_notices.reasoning_history_refused(event) if event[:type] == :reasoning_history_refused
        next thinking_notices.sampling_refused(event) if event[:type] == :sampling_refused

        event = with_generation_report(event) if event[:type] == :generation_completed
        emit_event(on_event, event)
        # What this request sends: both loops start a generation after
        # their apply_llm_context!.
        emit_working_set(on_event, session, live_conversation) if event[:type] == :generation_started
        watch.feed(**progress) if watch && progress
        thinking_notices.generation_completed(event) if event[:type] == :generation_completed
      end
    end

    # The working set (WorkingSet) as the model has it, as a
    # :working_set_updated event ({items:, at:}, adds: while the user's
    # adds are pending): at each request (the
    # stream handler's :generation_started, from the running turn's
    # conversation) and at turn end (#end_turn, from the session's kept
    # messages). Only when it differs from the last one emitted for this
    # session, and never while it is empty — except one empty event,
    # remembered, when the last one for this session had items (a
    # rollback removed the tool calls), so a tool-free turn emits none
    # and the next empty request sends nothing more. The web overlays it
    # on the rows' set; other UIs ignore it.
    #
    # Between turns (#announce_working_set: no +on_event+) it is
    # announced, under the next turn's strategy.
    def emit_working_set(on_event, session, conversation)
      return unless session && conversation

      snapshot = WorkingSet.build(conversation, cwd: session.working_directory, strategy: working_set_strategy,
                                  pins: session.working_set_pins)

      shown = snapshot.to_h.except(:at)
      last = @working_set_emitted
      if snapshot.empty?
        return unless last && last[0] == session.id && last[1] != { items: [] }
      elsif last == [session.id, shown]
        return
      end

      @working_set_emitted = [session.id, shown]
      event = { type: :working_set_updated, **shown, at: snapshot.at }
      on_event ? emit_event(on_event, event) : announce_or_hold(event)
    rescue StandardError => e
      Log.warn(:turn, "working_set_failed", error: e.class.name, msg: e.message.to_s[0, 200])
    end

    # The strategy the set is built under: the running turn's
    # (TurnSettings#llm_context: what its requests send); between turns
    # the next turn's (as #warm_up_next_turn: the turn's settings keep the
    # last turn's, stale after a /llm-context or /model change), the last
    # turn's when it can't be resolved.
    def working_set_llm_context
      turn = kernel.respond_to?(:turn_settings) ? kernel.turn_settings&.llm_context : nil
      return turn if turn_running?

      model_settings.turn_llm_context || turn
    end

    # A :generation_completed with the generation's decode speed (`speed:`
    # {decode_tps:, source:}, nil without one), the session's running
    # token totals (`tokens:`, the snapshot's block) and its per-model rows
    # (`model_segments:`, the snapshot's) and whether its served
    # model is an expected one (`served_expected_by:`, its host): the web's info bar
    # reads them from the stream. SessionMetrics closes the generation here,
    # so the event it gets next finds it closed.
    def with_generation_report(event)
      report = metrics.finish_generation
      event.merge(speed: report.speed&.to_h, tokens: report.tokens, model_segments: report.model_segments,
                  served_expected_by: served_expected_by(event[:served_model]))
    rescue StandardError => e
      Log.warn(:turn, "generation_report_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      event
    end

    # The turn's StreamWatch, or nil when no hook listens.
    def stream_watch(cancel_controller)
      return nil unless cancel_controller && hooks.any?(Hooks::StreamWatch::EVENT)

      Hooks::StreamWatch.new(hooks: hooks, cancel_controller: cancel_controller)
    end

    def emit_event(on_event, event)
      # Capture used memories synchronously in the turn thread.
      read_names = begin
        used_memories.capture(event, muted: muted)
      rescue StandardError => e
        Log.warn(:memory, "used_memories_capture_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      end
      # Turn-scoped sink: receives the event hash as the stream handler
      # passed it (no event_seq; a :generation_completed has its report). Sink errors are isolated and never break the
      # kernel loop (same as KernelLoop's own handling).
      if on_event
        begin
          on_event.call(event)
        rescue StandardError => e
          # Sink errors must not break the kernel loop (same as KernelLoop's own handling)
          Log.warn(:turn, "sink_failed", event_type: event[:type].to_s, error: e.class.name, msg: e.message.to_s[0, 200])
        end
      end

      # Persistent subscribers: receive a copy with a locally-monotonic
      # `event_seq`, fan out with per-subscriber error isolation.
      observer.notify(event)
      # Every memory read, after its tool_call_started: the whole list for
      # the UIs' memory line, and the names this call read (read_names).
      return unless read_names

      emit_event(on_event, { type: :used_memories_updated, used_memory_names: used_memory_names, read_names: read_names })
    end

    private

    def observer = @observer.call
    def used_memories = @used_memories.call
    def muted = @muted.call
    def steer_cut = @steer_cut.call
    def thinking_notices = @thinking_notices.call
    def metrics = @metrics.call
    def hooks = @hooks.call
    def kernel = @kernel.call
    def model_settings = @model_settings.call
    def session = @session.call
    def live_conversation = @live_conversation.call
    def used_memory_names = @used_memory_names.call
    def served_expected_by(served) = @served_expected_by.call(served)
    def working_set_strategy = @working_set_strategy.call
    def turn_running? = @turn_running.call
    def announce_or_hold(event) = @announce_or_hold.call(event)
  end
end
