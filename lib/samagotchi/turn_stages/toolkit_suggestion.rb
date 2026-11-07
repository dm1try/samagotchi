# frozen_string_literal: true

require_relative "../config"
require_relative "../log"
require_relative "../side_judgments"
require_relative "../system_one/client"
require_relative "../toolkit"
require_relative "../toolkit_suggest"
require_relative "../tools/tool_index"

module Samagotchi
  # The steps of a turn that keep state across its preparation, each a
  # collaborator the Engine builds from constructor arguments and
  # Engine#prepare_turn calls by name (docs/internals/engine.md, "Turn
  # stages").
  module TurnStages
    # System 1's toolkit suggestion (ToolkitSuggest): the ask a turn starts
    # before the probes, settles before apply_toolkit! (on mode) or abandons
    # at a Stop or a failure, and the idle worker's warm-up. Its state is
    # the running turn's Pending (turn thread only) and the warm-up thread.
    class ToolkitSuggestion
      # @param side_judgments [SideJudgments] the Engine's side asks (:toolkit kind)
      # @param host_registry [HostRegistry] System 1's client resolves its host here
      # @param toolkit_binding [ToolkitBinding] the kits, #suggest and #fell_back
      # @param tools [Tools::Registry] the registered tools, for the snapshot
      # @param state_dir [#call] the sessions dir (the suggestion log's place)
      # @param recording [#call] (client, judgment, session, mode:) → the client saving its runs
      # @param runs [#call] the Engine's SystemOne::Runs
      def initialize(side_judgments:, host_registry:, toolkit_binding:, tools:, state_dir:, recording:, runs:)
        @side_judgments = side_judgments
        @host_registry = host_registry
        @toolkit_binding = toolkit_binding
        @tools = tools
        @state_dir = state_dir
        @recording = recording
        @runs = runs
        @pending = nil
        @pending_turn = nil
        @warmup_thread = nil
      end

      # The running warm-up (#warm!), nil when none started or it was stopped.
      attr_reader :warmup_thread

      # The ask's thread (SideJudgments' :toolkit kind), nil before any.
      def ask_thread = @side_judgments.thread(:toolkit)

      # Start the toolkit classifier after :turn_started, for audit and on
      # mode alike (one eligibility, one snapshot, one thread). All session
      # and tool-registry reads happen here; the thread receives only this
      # snapshot. Audit never blocks: the thread logs its line. On mode
      # keeps the ask's Pending for +turn+, which #settle joins before
      # apply_toolkit!, with the turn's controller as the request's cancel
      # controller.
      # @return [ToolkitSuggest::Pending, nil] nil unless the turn joins an ask
      def start(turn)
        @pending = nil
        @pending_turn = turn
        @pending = ask(turn)
      end

      # On mode, before apply_toolkit!: wait for +turn+'s ask (#start) up to
      # System 1's timeout from its start, or until a Stop, and put the
      # session on a candidate picked with confidence ≥ threshold
      # (ToolkitBinding#suggest: origin suggested, saved, the notice). Any
      # other outcome (the default, below threshold, undecided, no judgment,
      # a timeout, a Stop) leaves the session on its default. Nothing here
      # sends a request; prepare_turn's cancel check ends a stopped turn. A
      # Stop wins over an answer already in (Pending#wait checks it first).
      def settle(turn)
        pending = pending_for(turn)
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

        pending.record(outcome_of(turn.session, judged))
      rescue StandardError => e
        ToolkitSuggest.warn(e)
        pending&.record("failed")
      end

      # +turn+ ended before it settled its ask (a Stop at the probes, a
      # failure, an Interrupt): the ask's line says +reason+
      # (Pending#abandon; nothing once it was settled, so prepare_turn's
      # ensure calls it too). Nothing when +turn+ started no ask.
      def abandon(turn, reason)
        pending_for(turn)&.abandon(reason)
      end

      # On mode, as an idle worker starts (Worker#start_background): one ask
      # with the real question and a stand-in prompt, on its own thread,
      # never logged and never waited for, so System 1's server has the
      # question's prefix cached for the first prompt. Only for a session a
      # first prompt could be asked for: origin default, no model reply, not
      # a delegate child or a review session, at least two candidates; and
      # not when the worker starts on a first prompt (that ask comes at once).
      def warm!(session)
        return unless Config.get("toolkit.suggest.mode").to_s == "on"

        return if session.nil? || session.toolkit_origin != "default" || session.delegate? || session.review?
        return if ToolkitSuggest.model_reply?(session.messages) || !session.last_prompt.to_s.strip.empty?

        default = Toolkit.of(session.toolkit)
        kits = @toolkit_binding.kits
        return if ToolkitSuggest.candidates(kits, default_name: default.name).size < 2

        client = SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :toolkit)
        return unless client

        project = File.basename(session.project_root.to_s)
        @warmup_thread = Thread.new do
          ToolkitSuggest.warm(client: client, default: default, kits: kits, project: project)
        end
      rescue StandardError => e
        ToolkitSuggest.warn(e)
        nil
      end

      # A still-running warm-up, stopped: a real ask (or the worker leaving)
      # doesn't wait behind it.
      def stop_warmup
        @warmup_thread&.kill
        @warmup_thread = nil
      end

      private

      # The Pending #start kept for this very turn: another turn's (one that
      # never reached #start) is never touched.
      def pending_for(turn) = (@pending if @pending_turn.equal?(turn))

      def ask(turn)
        mode = Config.get("toolkit.suggest.mode").to_s
        return if mode == "off"

        joined = mode == "on"
        session = turn.session
        default = Toolkit.of(session.toolkit)
        log = suggestion_log
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

        client = @recording.call(SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :toolkit),
                                 ToolkitSuggest::JUDGMENT, session, mode: Config.get("toolkit.suggest.mode").to_s)
        return unless client

        # The warm-up's only value is the cache: the real ask never queues
        # behind it.
        stop_warmup

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
        runs = session.scratch ? nil : @runs.call
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

      # What the turn does with an answered ask, as the log line's did:
      # suggested (switched), chosen (the toolkit isn't the default any
      # more), unavailable (the kit is gone), defer or default.
      def outcome_of(session, judged)
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

      def suggestion_log
        SideJudgments.log(ToolkitSuggest.log_path(@state_dir.call), tag: :toolkit, event: "toolkit_suggest_log_failed")
      end
    end
  end
end
