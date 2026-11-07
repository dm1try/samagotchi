# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's toolkit: the kits and what a turn declares
    # (ToolkitBinding, forwarded), ctx.load_tools and the staged loads a turn
    # appends, and System 1's toolkit suggestion (start, settle, warm-up).
    # Writes @toolkit_warmup_thread; reads @toolkit_binding, @tools,
    # @tool_index, @tool_loads, @side_judgments, @session.
    module ToolkitPart
      private

      # The session's toolkit (ToolkitBinding): the kits, what its next turn
      # declares, ctx.use_toolkit and the turn-start apply.
      def toolkit_kits(errors = []) = @toolkit_binding.kits(errors)
      def resolved_toolkit(session, errors = []) = @toolkit_binding.resolved(session, errors)
      def toolkit_explained(toolkit = nil) = @toolkit_binding.explained(toolkit)
      def toolkit_summary = @toolkit_binding.summary

      # The tools this session registered (Tools::Registry), declared or not.
      attr_reader :tools

      public :tools, :toolkit_kits, :resolved_toolkit, :toolkit_explained, :toolkit_summary

      # A plugin's ctx.load_tools: stage the reachable tools +names+ names
      # (Tools::ToolIndex#deferred_name) that the session neither declares
      # nor loaded with an earlier tool change, for bundle +bundle+. A name
      # that names no tool at all is logged; a declared or removed one is
      # skipped quietly.
      # @return [Array<String>] the wire names staged
      def load_tools(names, bundle)
        added = ToolLoads.added(@session&.messages)
        wanted = names.filter_map do |name|
          wire = @tool_index.deferred_name(name)
          Log.info(:plugins, "load_tools_skipped", bundle: bundle, tool: name) unless wire || @tools.key?(name)
          wire
        end
        @tool_loads.stage(wanted - added, by: bundle)
      end
      public :load_tools

      # The staged tool loads, appended to +turn+'s messages (after its user
      # message, or the trailing results and notes of a turn with none) as
      # one ToolLoads entry per bundle, when the turn's host takes tool
      # changes (ChatLoop#tool_changes?). Elsewhere they are dropped, logged.
      # A conversation that ends with a reply keeps them staged (a system
      # change must follow a user turn).
      def append_tool_loads(turn)
        return unless @tool_loads.any?
        return if turn.messages.last&.dig(:role).to_s == "model"

        model = effective_model
        host = backend(model)
        staged = @tool_loads.take
        added = ToolLoads.added(turn.messages)
        unless host.respond_to?(:tool_changes?) && host.tool_changes?(bare_model_name(model.name))
          Log.info(:plugins, "tool_loads_not_sent", tools: staged.values.flatten.join(","), model: model.name.to_s)
          return
        end

        staged.each do |bundle, names|
          names -= added
          next if names.empty?

          turn.messages << ToolLoads.entry(names, by: bundle)
          hook_notify("tools loaded: #{names.join(", ")}", :info, bundle)
        end
      end
      private :append_tool_loads

      # A plugin's ctx.use_toolkit (ToolkitBinding#use).
      # @return [Boolean] whether it was staged
      # @raise [ArgumentError] an unknown toolkit
      def use_toolkit(name) = @toolkit_binding.use(name)
      public :use_toolkit

      # At a turn's start (ToolkitBinding#apply!).
      # @return [Boolean] whether the declared tools changed
      def apply_toolkit!(session, on_event = nil) = @toolkit_binding.apply!(session, on_event)
      private :apply_toolkit!

      # Start the toolkit classifier after :turn_started, for audit and on
      # mode alike (one eligibility, one snapshot, one thread). All session
      # and tool-registry reads happen here; the thread receives only this
      # snapshot. Audit never blocks: the thread logs its line. On mode
      # returns the ask's Pending, which the turn joins before apply_toolkit!
      # (#settle_toolkit_suggestion), with the turn's controller as the
      # request's cancel controller.
      # @return [ToolkitSuggest::Pending, nil] nil unless the turn joins an ask
      def start_toolkit_suggestion(turn)
        mode = Config.get("toolkit.suggest.mode").to_s
        return if mode == "off"

        joined = mode == "on"
        session = turn.session
        default = Toolkit.of(session.toolkit)
        log = toolkit_suggestion_log
        # The predicate checks the session first; the kits (memory kits are
        # read from disk) and the log (read whole) only when it gets there.
        kits = nil
        candidates = nil
        return unless ToolkitSuggest.eligible?(
          session: session, prompt: turn.prompt, author: turn.origin.author,
          candidate_count: lambda {
            kits = @toolkit_binding.kits
            candidates = ToolkitSuggest.candidates(kits, default_name: default.name)
            candidates.size
          },
          last_suggestion: -> { ToolkitSuggest.last_suggestion(log, session.id) },
          defer_turns: Config.get("toolkit.suggest.defer_turns"),
          defer_tokens: Config.get("toolkit.suggest.defer_tokens")
        )

        # One ask at a time: an eligible turn while the last one still runs
        # goes unasked, and says so.
        if @side_judgments.in_flight?(:toolkit)
          Log.info(:toolkit, "toolkit_suggest_in_flight_skipped", session_id: session.id)
          return
        end

        client = system_one_recording(SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :toolkit),
                                      ToolkitSuggest::JUDGMENT, session, mode: Config.get("toolkit.suggest.mode").to_s)
        return unless client

        # The warm-up's only value is the cache: the real ask never queues
        # behind it.
        stop_toolkit_warmup

        # Rules, not tool lists: this runs before await_init_tasks and
        # apply_staged_tools!, so a first turn's plugin/MCP tools aren't
        # registered yet; the report expands the rules (ToolkitSuggest.rules).
        snapshots = candidates.map do |kit|
          ToolkitSuggest::Candidate.new(name: kit.name.dup.freeze, description: kit.description.dup.freeze,
                                        rules: ToolkitSuggest.rules(Toolkit.resolve_kit(kit.name, kits)))
        end.freeze
        default_snapshot = ToolkitSuggest::Candidate.new(name: default.name.dup.freeze, description: nil,
                                                         rules: ToolkitSuggest.rules(default.resolve(kits)))
        registered = @tools.entries(toolkit: nil).reject { |entry| entry.source == Tools::ToolIndex::SOURCE }
        core_tools, plugin_tools = registered.partition(&:core?).map { |entries| entries.map { |entry| entry.name.dup.freeze }.freeze }
        state = ToolkitSuggest.question(
          default: default, kits: kits, project: File.basename(session.project_root.to_s),
          prompt: turn.prompt
        ).last
        snapshot = ToolkitSuggest::Snapshot.new(
          session_id: session.id.dup.freeze, turn_number: ToolkitSuggest.turn_number(session.messages),
          default: default_snapshot, candidates: snapshots, core_tools: core_tools, plugin_tools: plugin_tools,
          state: { project: state[:project].dup.freeze, prompt: state[:prompt].dup.freeze }.freeze
        )
        threshold = Config.get("toolkit.suggest.threshold")
        runs = session.scratch ? nil : system_one_runs
        pending = ToolkitSuggest::Pending.new(log: log, joined: joined,
                                              acted: runs && ->(judged, did) { runs.acted(judged.fields[:run_id], did) },
                                              timeout_seconds: SystemOne::Client.configured_timeout_ms / 1000.0)
        # On mode: cut by a Stop while the turn waits (Pending#wait), not
        # by one after it went on; audit's ask is never cut.
        controller = joined ? pending.cancel_controller : nil
        @side_judgments.start(:toolkit, warn: ToolkitSuggest.method(:warn), finish: pending.method(:finish)) do
          ToolkitSuggest.judge(client: client, snapshot: snapshot, threshold: threshold,
                               cancel_controller: controller)
        end
        joined ? pending : nil
      rescue StandardError => e
        ToolkitSuggest.warn(e)
        nil
      end
      private :start_toolkit_suggestion

      # On mode, before apply_toolkit!: wait for the ask (#start_toolkit_
      # suggestion) up to System 1's timeout from its start, or until a Stop,
      # and put the session on a candidate picked with confidence ≥ threshold
      # (ToolkitBinding#suggest: origin suggested, saved, the notice). Any
      # other outcome (the default, below threshold, undecided, no judgment,
      # a timeout, a Stop) leaves the session on its default. Nothing here
      # sends a request; prepare_turn's cancel check ends a stopped turn. A
      # Stop wins over an answer already in (Pending#wait checks it first).
      def settle_toolkit_suggestion(turn, pending)
        return if pending.nil?

        outcome, judged = pending.wait(turn.controller)
        if outcome == :timeout
          # The session starts on its default without a word otherwise: a
          # slow System 1 host (a local one) is the usual cause.
          timeout_ms = SystemOne::Client.configured_timeout_ms
          Log.warn(:toolkit, "toolkit_suggest_timeout", session_id: turn.session.id, timeout_ms: timeout_ms,
                                                        reason: "System 1 gave no answer within system_one.timeout_ms")
          @toolkit_binding.fell_back(turn.session, "System 1 took over #{timeout_ms} ms")
          return
        end
        unless outcome == :answered
          Log.info(:toolkit, "toolkit_suggest_#{outcome}", session_id: turn.session.id)
          return
        end
        return if judged.nil?

        pending.record(toolkit_suggestion_outcome(turn.session, judged))
      rescue StandardError => e
        ToolkitSuggest.warn(e)
        pending&.record("failed")
      end
      private :settle_toolkit_suggestion

      # What the turn does with an answered ask, as the log line's did:
      # suggested (switched), chosen (the toolkit isn't the default any
      # more), unavailable (the kit is gone), defer or default.
      def toolkit_suggestion_outcome(session, judged)
        case judged.would
        when "suggested"
          return "chosen" unless session.toolkit_origin == "default"
          return "unavailable" unless @toolkit_binding.kits.key?(judged.suggestion.kit)

          switched = @toolkit_binding.suggest(session, judged.suggestion.kit, confidence: judged.suggestion.confidence,
                                                                              deferred: ToolkitSuggest.model_reply?(session.messages))
          switched ? "suggested" : "chosen"
        when "defer" then "defer"
        when "no_judgment"
          # System 1 failed (its own warn) or answered nothing usable.
          @toolkit_binding.fell_back(session, "System 1 gave no answer")
          "default"
        else "default"
        end
      end
      private :toolkit_suggestion_outcome

      # On mode, as an idle worker starts (Worker#start_background): one ask
      # with the real question and a stand-in prompt, on its own thread,
      # never logged and never waited for, so System 1's server has the
      # question's prefix cached for the first prompt. Only for a session a
      # first prompt could be asked for: origin default, no model reply, not
      # a delegate child or a review session, at least two candidates; and
      # not when the worker starts on a first prompt (that ask comes at once).
      def warm_toolkit_suggestion!
        return unless Config.get("toolkit.suggest.mode").to_s == "on"

        session = @session
        return if session.nil? || session.toolkit_origin != "default" || session.delegate? || session.review?
        return if ToolkitSuggest.model_reply?(session.messages) || !session.last_prompt.to_s.strip.empty?

        default = Toolkit.of(session.toolkit)
        kits = @toolkit_binding.kits
        return if ToolkitSuggest.candidates(kits, default_name: default.name).size < 2

        client = SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :toolkit)
        return unless client

        project = File.basename(session.project_root.to_s)
        @toolkit_warmup_thread = Thread.new do
          ToolkitSuggest.warm(client: client, default: default, kits: kits, project: project)
        end
      rescue StandardError => e
        ToolkitSuggest.warn(e)
        nil
      end
      public :warm_toolkit_suggestion!

      # A still-running warm-up, stopped: a real ask (or the worker leaving)
      # doesn't wait behind it.
      def stop_toolkit_warmup
        @toolkit_warmup_thread&.kill
        @toolkit_warmup_thread = nil
      end
      private :stop_toolkit_warmup

      def toolkit_suggestion_log
        SideJudgments.log(ToolkitSuggest.log_path(session_state_dir), tag: :toolkit, event: "toolkit_suggest_log_failed")
      end
      private :toolkit_suggestion_log
    end
  end
end
