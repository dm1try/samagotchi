# frozen_string_literal: true

require_relative "context_status"
require_relative "effective_model"
require_relative "sampling_settings"
require_relative "session_setting"
require_relative "steer_cut"
require_relative "steer_cut_after"
require_relative "thinking"

module Samagotchi
  # The session's settings on its effective model, as the Engine reads them:
  # the session's own thinking, reasoning_history and llm_context values
  # (SessionSetting) over the effective model's (EffectiveModel), the
  # summaries /model and /stats show, and what the next turn resolves.
  # Every read resolves the model again (EffectiveModel.of, never kept); a
  # reader with a fallback gives it when the model doesn't resolve
  # (#model_setting). The Engine forwards its public readers here.
  class SessionModelSettings
    # @param registry [HostRegistry] the Engine's (never replaced)
    # @param choice   [#call] → the ModelChoice turns run on now (/model moves it)
    # @param session  [#call] → the Engine's Session, nil before one
    def initialize(registry:, choice:, session:)
      @registry = registry
      @choice = choice
      @session = session
    end

    # The effective model now (EffectiveModel.of): resolved on each call,
    # never kept (config.yml, a model listing and another process's saved
    # lists all move a resolve). Raises as HostRegistry#resolve does.
    # @return [EffectiveModel]
    def effective_model(choice = @choice.call) = EffectiveModel.of(@registry, choice)

    # The block's answer for the effective model, or +fallback+ when the
    # model doesn't resolve: the readers whose rescue always covered the
    # resolve too. Each setting's own failure is the EffectiveModel's.
    def model_setting(fallback)
      # One read: the log line names the model that failed, even if a
      # /model switched it meanwhile.
      choice = @choice.call
      model = begin
        effective_model(choice)
      rescue StandardError => e
        return EffectiveModel::Unresolved.fallback(:effective_model_unresolved, choice.name, e, fallback)
      end
      yield model
    end

    # The status line's ctx from the saved context, for a worker that has run
    # no turn yet (it woke after an idle exit): nil when either count is
    # unknown or context.status is off. Counted as the turns count it:
    # against the effective model's llm_context budget when it has one.
    def saved_context_status(context, model: :current)
      return nil unless context

      llm_context = model == :current ? turn_llm_context : model&.llm_context_explained(llm_context_session_args)&.resolved
      ContextStatus.new(llm_context: llm_context)
                   .display_for(used_tokens: context[:used_tokens], window_tokens: context[:window_tokens])
    end

    # #turn_llm_context with where each value came from
    # (LLMContextStrategy.explain), nil when it can't be resolved.
    # @return [LLMContextStrategy::Explained, nil]
    def llm_context_explained
      model_setting(nil) { |model| model.llm_context_explained(llm_context_session_args) }
    end

    # #llm_context_explained's summary (Explained#summary), nil when it
    # can't be resolved: /stats, the snapshot, the web's info bar.
    # @return [Hash, nil]
    def llm_context_summary
      llm_context_explained&.summary(llm_context_override)
    end

    # The session's own llm_context values, nil when it has none.
    # @return [LLMContextOverride, nil]
    def llm_context_override = SessionSetting::LLM_CONTEXT.own(@session.call)

    # The effective model is on a chat host (api: openai or anthropic), whose loop uses
    # no prompt profile.
    def chat_model? = effective_model.chat?

    # "temperature=0.6 (hosts.work)" for /model: the effective model's
    # configured sampling, nil when none.
    def sampling_summary = model_setting(nil, &:sampling_summary)

    # "off (models: qwen)", "low (session)" for /model: the effective
    # model's thinking level and where it came from, nil when none is set.
    def thinking_summary
      explained = thinking_explained
      explained&.source ? explained.label : nil
    end

    # The seconds a cut waits for the effective model to stream only
    # thinking (SteerCutAfter.resolve), resolved on every call, as
    # turn_sampling; on any error, the global and its name.
    # @return [Array(Integer, String|nil)]
    def steer_cut_after_explained
      model_setting([SteerCut.cut_after, "steer.cut_after"], &:steer_cut_after_explained)
    end

    # #steer_cut_after_explained's seconds: what SteerCut#cut_for_steer
    # reads, per host and model.
    def steer_cut_after = steer_cut_after_explained.first

    # "after 60 s (models: qwen)", "never (hosts.splash)" for /model: the
    # effective model's cut wait and where it came from, nil for the
    # default.
    def steer_cut_summary
      seconds, source = steer_cut_after_explained
      source ? SteerCutAfter.label(seconds, source) : nil
    end

    # The effective model's thinking level with where it came from and the
    # session's own (SettingExplained), as the next turn resolves it;
    # nil when it can't be resolved.
    # @return [SettingExplained, nil]
    # +own+: the session's own level to resolve with (the current one by
    # default; /thinking asks what a change would resolve to).
    def thinking_explained(own: thinking_override)
      model_setting(nil) { |model| model.thinking_explained(own: own) }
    end

    # "drop (models: qwen)" for /model: the effective chat model's
    # reasoning_history level and where it came from; nil when it is the
    # default, the model runs on the native loop (which ignores it) or it
    # can't be resolved.
    def reasoning_history_summary
      model_setting(nil) { |model| model.reasoning_history_summary(own: reasoning_history_override) }
    end

    # The effective chat model's reasoning_history level with where it came
    # from and the session's own (SettingExplained), as the next turn
    # resolves it; nil on a native host (the native loop ignores it; native:
    # true resolves it there too, for /reasoning-history) or when it can't
    # be resolved.
    # @return [SettingExplained, nil]
    # +own+: the session's own level to resolve with (the current one by
    # default; a command asks what a change would resolve to).
    def reasoning_history_explained(native: false, own: reasoning_history_override)
      model_setting(nil) { |model| model.reasoning_history_explained(own: own, native: native) }
    end

    # What a reasoning_history change from level +from+ to level +to+ costs
    # the effective model's prompt cache, given the session's conversation
    # (ReasoningHistory.cache_cost): :history or nil. A host ChatLoop
    # marked as refusing it may still get :history (one needless ask).
    # @return [Symbol, nil]
    def reasoning_history_cache_cost(from, to)
      model_setting(nil) { |model| model.reasoning_history_cache_cost(from, to, conversation: @session.call&.messages) }
    end

    # The session's own reasoning_history level, nil when it has none.
    # @return [Symbol, nil]
    def reasoning_history_override = SessionSetting::REASONING_HISTORY.own(@session.call)

    # Set the session's own reasoning_history level (nil unsets it); the
    # next turn's start resolves it. The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def reasoning_history_override=(level)
      session = @session.call
      raise ArgumentError, "no session yet" unless session

      SessionSetting::REASONING_HISTORY.set(session, level)
    end

    # The session's own thinking level, nil when it has none.
    # @return [Symbol, nil]
    def thinking_override = SessionSetting::THINKING.own(@session.call)

    # Set the session's own thinking level (nil unsets it); the next turn's
    # start resolves it, never a running one (its TurnSettings are fixed).
    # The caller saves the session.
    # @raise [ArgumentError] with no session yet
    def thinking_override=(level)
      session = @session.call
      raise ArgumentError, "no session yet" unless session

      SessionSetting::THINKING.set(session, level)
    end

    # The host whose hosts.<name>.models.<id>.served names +served+ for the
    # current model (a gateway's round-robin targets): not a mismatch to
    # warn about. nil when none does.
    # @return [String, nil]
    def served_expected_by(served)
      model_setting(nil) { |model| model.served_expected_by(served) }
    end

    def served_expected?(served) = !served_expected_by(served).nil?

    # The effective model's request parameters (hosts: and models:
    # sampling), read per turn: /model can change the model between turns.
    def turn_sampling = model_setting(SamplingSettings::EMPTY, &:sampling)

    # The effective model's thinking level (Thinking.resolve), read each turn.
    def turn_thinking = model_setting(Thinking::DEFAULT) { |model| thinking_level(model) }

    # +model+'s ReasoningHistory level, the session's own first; the
    # default when it can't be resolved.
    def reasoning_history_level(model) = model.reasoning_history(own: reasoning_history_override)

    # +model+'s thinking level (Thinking.resolve), the session's own first.
    def thinking_level(model) = model.thinking(own: thinking_override)

    # The effective model's models:/hosts: window_tokens, read per turn
    # (after the hooks that may switch the model).
    def turn_window_setting = model_setting(nil, &:window_setting)

    # The effective model's price on its host (hosts.<name>.models.<id>.price),
    # by the requested id, never the served one; read per turn as the window is.
    def turn_price = model_setting(nil, &:price)

    # The LLM context strategy the next turn runs under: the session's own
    # (Session#llm_context), else the effective model's (models:/hosts:
    # llm_context_strategy), else llm_context.strategy; read per turn as
    # the window is.
    def turn_llm_context
      llm_context_explained&.resolved
    end

    # The session's own llm_context values as LLMContextStrategy's
    # arguments ({} without a session or values).
    def llm_context_session_args = @session.call&.llm_context&.resolve_args || {}
  end
end
