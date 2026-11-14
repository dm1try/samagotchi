# frozen_string_literal: true

require_relative "../session_setting"

module Samagotchi
  class Engine
    # The session's settings on its effective model (SessionModelSettings) and
    # the UIs' snapshots (EngineSnapshots), forwarded: /model's and /stats'
    # summaries, the overrides a session saves, what a turn reads. Writes
    # @last_context_status; reads @model_settings, @engine_snapshots, @metrics.
    module ModelSettingsPart
      # The metrics for /stats, which may make one short /props GET
      # (EngineSnapshots#stats_snapshot).
      # @return [Hash] @metrics.snapshot, filled in
      def stats_snapshot = @engine_snapshots.stats_snapshot

      # ── The session's model settings (SessionModelSettings) ──────────────────

      # The session's own thinking, reasoning_history and llm_context values
      # over the effective model's, the summaries /model and /stats show, and
      # the saved context's status: SessionModelSettings' (resolved on every
      # read); these forward.
      def saved_context_status(context, model: :current) = @model_settings.saved_context_status(context, model: model)
      def llm_context_explained(own: :session) = @model_settings.llm_context_explained(own: own)
      def llm_context_summary = @model_settings.llm_context_summary
      def llm_context_override = @model_settings.llm_context_override
      def chat_model? = @model_settings.chat_model?
      def sampling_summary = @model_settings.sampling_summary
      def thinking_summary = @model_settings.thinking_summary
      def steer_cut_after_explained = @model_settings.steer_cut_after_explained
      def steer_cut_after = @model_settings.steer_cut_after
      def steer_cut_summary = @model_settings.steer_cut_summary
      def thinking_explained(own: thinking_override) = @model_settings.thinking_explained(own: own)
      def reasoning_history_summary = @model_settings.reasoning_history_summary
      def reasoning_history_cache_cost(from, to) = @model_settings.reasoning_history_cache_cost(from, to)
      def reasoning_history_override = @model_settings.reasoning_history_override
      def thinking_override = @model_settings.thinking_override
      def served_expected_by(served) = @model_settings.served_expected_by(served)
      def served_expected?(served) = @model_settings.served_expected?(served)

      def reasoning_history_explained(native: false, own: reasoning_history_override)
        @model_settings.reasoning_history_explained(native: native, own: own)
      end

      # Set the session's own reasoning_history or thinking level (nil unsets
      # it): SessionModelSettings'. The caller saves the session.
      # @raise [ArgumentError] with no session yet
      def reasoning_history_override=(level)
        @model_settings.reasoning_history_override = level
      end

      def thinking_override=(level)
        @model_settings.thinking_override = level
      end

      # Set the session's own llm_context values (an empty override unsets
      # them); the next turn's start resolves them, never a running one (its
      # TurnSettings are fixed). The caller saves the session.
      # @raise [ArgumentError] with no session yet
      def llm_context_override=(override)
        raise ArgumentError, "no session yet" unless @session

        SessionSetting::LLM_CONTEXT.set(@session, override)
        # The status a later client reads counts against the new budget.
        @last_context_status = saved_context_status(@metrics.snapshot[:context]) || @last_context_status if @last_context_status
      end

      # Whether the session has a model reply (a cache to restart at all).
      def history?
        Array(@session&.messages).any? { |entry| entry[:role].to_s == "model" }
      end

      # The latest known context size used by a request, for a cache-restart
      # confirmation; nil before any request reports a count.
      # @return [Integer, nil]
      def cache_restart_tokens
        used = @metrics.snapshot.dig(:context, :used_tokens)
        used if used.is_a?(Integer)
      end

      # Whether a cache restart can invalidate preserved thinking blocks.
      def cache_restart_anthropic?
        effective_model.entry&.api.to_s == "anthropic"
      end

      # What a thinking level change costs the effective model's prompt
      # cache (Thinking.cache_cost): :full, :provider or :tail.
      # @return [Symbol]
      def thinking_cache_cost
        effective_model.thinking_cache_cost { profile }
      end

      # The model the server serves for the current model, and the name asked
      # for: what the last generation of that name reported, else llama.cpp's
      # model_alias (/props, one short cached probe; not with probe: false),
      # else [nil, nil].
      # @return [Array(String, String), Array(nil, nil)]
      def served_model(probe: true)
        @engine_snapshots.served_model_for(@metrics.served_report, model: probe ? effective_model : nil)
      end

      # Read-only snapshot of the engine's view of the current session plus the
      # live event sequence; cheap, never probes, never raises
      # (EngineSnapshots#session_state_snapshot has its keys).
      # @return [Hash]
      def session_state_snapshot = @engine_snapshots.session_state_snapshot

      # The effective model's sampling and thinking level as the next turn
      # reads them (SessionModelSettings).
      def turn_sampling = @model_settings.turn_sampling
      def turn_thinking = @model_settings.turn_thinking

      private

      # The effective model's window_tokens and price, read per turn
      # (SessionModelSettings).
      def turn_window_setting = @model_settings.turn_window_setting
      def turn_price = @model_settings.turn_price

      # The snapshots' helpers are EngineSnapshots' (#build_engine_snapshots);
      # these forward to it.
      def served_model_for(...) = @engine_snapshots.served_model_for(...)
      def kit_prompt_stats = @engine_snapshots.kit_prompt_stats

      # +settings+' chips (EngineSnapshots#setting_chips).
      def setting_chips(settings, model) = @engine_snapshots.setting_chips(settings, model)
    end
  end
end
