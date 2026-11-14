# frozen_string_literal: true

require_relative "../working_set"
require_relative "../llm_context_view"
require_relative "../session_setting"
require_relative "../memory_paths"
require_relative "participant_view"

module Samagotchi
  module Web
    # The working set's routes (web.working_set), mixed into App. See
    # docs/internals/working-set.md (Delivery).
    module WorkingSetRoutes
      # What a working-set build reads off a session: its +messages+ (symbol
      # keys at the top, as paired_runs reads them), the +strategy+ its
      # llm_context summary names, its folder (+cwd+) and its +pins+.
      Source = Data.define(:messages, :strategy, :cwd, :pins)

      private

      # GET /api/sessions/:id/working_set: the working set as the model has
      # it ({items:, at:, running:}, WorkingSet), what the page overlays on its rows'
      # set when it seeds a session's and when the expanded view opens (a
      # file changed while the session sat idle). A live worker's snapshot
      # messages are the truth, as #handle_show's, else the file's; the
      # strategy is the session's llm_context summary's, the folder its working
      # directory. running: a turn runs. The snapshot's messages lag it, so
      # the answer is then the turn's last :working_set_updated (the
      # snapshot's working_set, TurnAccumulator#working_set); before the
      # turn emitted one, or from an older worker without the field, it is
      # the session's messages, behind that turn's events, and the page
      # keeps theirs (working_set.js newerSnapshot).
      # A participant's is filtered (ParticipantView.working_set: the
      # project's files only).
      def handle_working_set(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        set = working_set_payload(id, session)
        return json_response(200, set) if principal(req).owner?

        viewer = participant_viewer(req, session)
        # Redacted as the stream's event is (ParticipantView.event): a file name may hold a secret's shape.
        shown = Redact.deep(ParticipantView.working_set(set, viewer), viewer)
        json_response(200, shown.merge("running" => set[:running] == true))
      end

      # GET /api/sessions/:id/working_set/item?kind=&key=[&now=1]: what the
      # model has of one item, its timeline (WorkingSet.timeline_of: every
      # run of it, in conversation order), the reader's and the popover
      # peek's. Owner only. Always built from messages, unlike the set's
      # route: the worker's snapshot messages (they lag a running turn's
      # events; the page asks again on its next :working_set_updated), else
      # the file's. Whole texts: the tool limits bound them (read's
      # truncate_at_bytes, the ToolRunner cap). +now+ (a memory): what its
      # latest read would answer now and the diff (WorkingSet.memory_now).
      def handle_working_set_item(req, id)
        kind = req.params["kind"].to_s
        key = req.params["key"].to_s
        unless [WorkingSet::FILE, WorkingSet::MEMORY, WorkingSet::URL].include?(kind) && !key.strip.empty?
          return error_response(400, "invalid_item", "expected kind (file, memory or url) and key")
        end

        session = @session_class.load(id, state_dir: default_state_dir)
        source = working_set_source(bridge_get_json(id, "snapshot"), session)
        timeline = WorkingSet.timeline_of(source.messages, kind: kind, key: key, strategy: source.strategy, cwd: source.cwd)
        body = timeline.to_h
        if req.params["now"] == "1" && kind == WorkingSet::MEMORY
          body[:now] = WorkingSet.memory_now(source.messages, key: key, strategy: source.strategy, cwd: source.cwd,
                                             root: MemoryPaths.system_dir)&.to_h
        end
        json_response(200, body)
      end

      def working_set_payload(id, session)
        live = bridge_get_json(id, "snapshot")
        worker_snapshot = live && live["snapshot"]
        running = !worker_snapshot&.dig("current_turn").nil?
        turn_set = running && running_working_set(live["snapshot"]["working_set"])
        return turn_set.merge(running: true) if turn_set

        idle_set = idle_working_set(worker_snapshot && worker_snapshot["idle_working_set"]) unless running
        return idle_set.merge(running: false) if idle_set

        source = working_set_source(live, session)
        snapshot = WorkingSet.build(source.messages, cwd: source.cwd, strategy: source.strategy, pins: source.pins)
        snapshot.to_h.merge(running: running)
      end

      # What a build from messages reads (+live+: the worker's Bridge
      # snapshot answer, nil without a worker): the worker's snapshot
      # messages, as #handle_show reads them, else the file's; the strategy
      # the worker's llm_context summary names, else the saved chip's.
      # @return [Source]
      def working_set_source(live, session)
        messages = live_or_saved(live && live["snapshot"], "messages") { session.messages }
        # A snapshot's entries have string keys (paired_runs reads symbols).
        messages = Array(messages).map { |message| message.is_a?(Hash) ? message.transform_keys(&:to_sym) : message }
        llm_context = SessionSetting::LLM_CONTEXT.snapshot_value(live && live["session_state_snapshot"]) do
          SessionSetting::LLM_CONTEXT.saved_summary(session, registry: host_registry)
        end
        Source.new(messages: messages, strategy: working_set_strategy(llm_context), cwd: session.working_directory,
                   pins: session.working_set_pins)
      end

      # The running turn's set from a worker's snapshot ({"items", "at"}), as
      # {items:, at:}; nil when it has none (none emitted yet, an older worker).
      def running_working_set(set)
        return nil unless set.is_a?(Hash) && set["items"].is_a?(Array) && set["at"].is_a?(Integer)

        { items: set["items"], at: set["at"] }
      end

      # The worker's between-turns working set ({"items", "at", optional
      # "adds"}); nil for an older or malformed snapshot.
      def idle_working_set(set)
        return nil unless set.is_a?(Hash) && set["items"].is_a?(Array) && set["at"].is_a?(Integer)
        return nil if set.key?("adds") && !set["adds"].is_a?(Array)

        { items: set["items"], at: set["at"] }.tap do |snapshot|
          snapshot[:adds] = set["adds"] if set.key?("adds")
        end
      end

      # The strategy an llm_context summary names ("none", "stale,forget"), as
      # LLMContextView takes it; none when there is no chip.
      def working_set_strategy(llm_context)
        named = llm_context.is_a?(Hash) ? (llm_context[:strategy] || llm_context["strategy"]).to_s : ""
        layers = named.split(",").map(&:strip).reject { |layer| layer.empty? || layer == "none" }
        layers.empty? ? LLMContextView::NONE : layers.map(&:to_sym)
      end
    end
  end
end
