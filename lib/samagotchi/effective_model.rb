# frozen_string_literal: true

require_relative "host_registry"
require_relative "log"
require_relative "context_window"
require_relative "llm_context_strategy"
require_relative "model_profile"
require_relative "reasoning_history"
require_relative "sampling_settings"
require_relative "served_model"
require_relative "steer_cut"
require_relative "steer_cut_after"
require_relative "thinking"
require_relative "vision_support"

module Samagotchi
  # The model a session runs on, as set: the name (maybe an alias;
  # HostRegistry#resolve applies it) and the name as typed at start or at
  # the last /model. One value, swapped in one assignment, so a reader on
  # another thread never pairs one model's name with another's typed name.
  ModelChoice = Data.define(:name, :typed)

  # The effective model resolved once (HostRegistry#resolve: its host and
  # client, the id sent) with the names its models: entry may be under
  # (HostRegistry#lookup_names), and its settings read from them. An
  # immutable snapshot built per read, never kept across reads: config.yml,
  # a model listing (which may move a bare id to another host) and another
  # process's saved lists all change what a resolve gives without any
  # /model. Frozen, so any thread may hold one.
  #
  # Each setting reader rescues its own failure and gives the fallback the
  # Engine has always given (Unresolved); building one raises as
  # HostRegistry#resolve does (the Engine's #model_setting gives the
  # fallback then).
  EffectiveModel = Data.define(:registry, :name, :typed, :target, :names) do
    # @param registry [HostRegistry]
    # @param choice [ModelChoice]
    # @raise what HostRegistry#resolve raises
    def self.of(registry, choice)
      target = registry.resolve(choice.name)
      new(registry: registry, name: choice.name, typed: choice.typed, target: target,
          names: registry.lookup_names(choice.typed, resolved: choice.name, target: target))
    end

    # A saved session's model (no worker): its model name, the default when
    # blank, and the name it was typed as.
    # @param session [Session]
    def self.of_session(session, registry:)
      name = session.model_name.to_s.strip.empty? ? ModelProfile.required_model_name(nil) : session.model_name
      of(registry, ModelChoice.new(name: name, typed: session.model_typed || name))
    end

    def entry = target.entry
    def client = target.client
    def bare = target.bare_model
    def host_name = entry.name

    # A chat host (api: openai or anthropic), whose loop uses no prompt profile.
    def chat? = entry.chat?

    # The resolved ref a session stores (ModelRef#ref): no resolve.
    def ref = registry.model_ref(name).ref

    # The configured request parameters (hosts: and models: sampling).
    def sampling
      SamplingSettings.for(target, names: names)
    rescue StandardError => e
      unresolved(:sampling_unresolved, e, SamplingSettings::EMPTY)
    end

    # "temperature=0.6 (hosts.work)", nil when none.
    def sampling_summary
      SamplingSettings.summary(target, names: names)
    rescue StandardError => e
      unresolved(:sampling_unresolved, e, nil)
    end

    # The thinking level (Thinking.resolve), the session's +own+ first.
    def thinking(own:)
      Thinking.resolve(target, names: names, session: own).first
    rescue StandardError => e
      unresolved(:thinking_unresolved, e, Thinking::DEFAULT)
    end

    # The thinking level with where it came from (SettingExplained), nil
    # when it can't be resolved.
    def thinking_explained(own:)
      Thinking.explain(target, names: names, session: own)
    rescue StandardError => e
      unresolved(:thinking_unresolved, e, nil)
    end

    # What a thinking level change costs the prompt cache
    # (Thinking.cache_cost); the block gives the prompt profile, asked only
    # on a native host. Raises.
    # @return [Symbol]
    def thinking_cache_cost(&)
      Thinking.cache_cost(target, profile: entry&.chat? ? nil : yield&.name)
    end

    # The reasoning_history level (ReasoningHistory.resolve), the session's
    # +own+ first.
    def reasoning_history(own:)
      ReasoningHistory.resolve(target, names: names, session: own).first
    rescue StandardError => e
      unresolved(:reasoning_history_unresolved, e, ReasoningHistory::DEFAULT)
    end

    # The reasoning_history level with where it came from (SettingExplained);
    # nil on a native host unless +native+ (its loop ignores the level), or
    # when it can't be resolved.
    def reasoning_history_explained(own:, native: false)
      return nil unless native || entry&.chat?

      ReasoningHistory.explain(target, names: names, session: own)
    rescue StandardError => e
      unresolved(:reasoning_history_unresolved, e, nil)
    end

    # "drop (models: qwen)"; nil for the default, on a native host, or when
    # it can't be resolved.
    def reasoning_history_summary(own:)
      return nil unless entry&.chat?

      level, source = ReasoningHistory.resolve(target, names: names, session: own)
      source ? ReasoningHistory.label(level, source) : nil
    rescue StandardError => e
      unresolved(:reasoning_history_unresolved, e, nil)
    end

    # What a reasoning_history change from +from+ to +to+ costs the prompt
    # cache, given +conversation+ (ReasoningHistory.cache_cost).
    def reasoning_history_cache_cost(from, to, conversation:)
      ReasoningHistory.cache_cost(from, to, target: target, conversation: conversation)
    rescue StandardError => e
      unresolved(:reasoning_history_unresolved, e, nil)
    end

    # [seconds, source] a cut waits for thinking (SteerCutAfter.resolve);
    # the global and its name when it can't be resolved.
    def steer_cut_after_explained
      SteerCutAfter.resolve(target, names: names)
    rescue StandardError => e
      unresolved(:steer_cut_after_unresolved, e, [SteerCut.cut_after, "steer.cut_after"])
    end

    # The LLM context strategy with where each value came from
    # (LLMContextStrategy.explain) under the session's +args+
    # (LLMContextOverride#resolve_args), nil when it can't be resolved.
    def llm_context_explained(args)
      LLMContextStrategy.explain(target, names: names, **args)
    rescue StandardError => e
      unresolved(:llm_context_unresolved, e, nil)
    end

    # The LLM context layers its turns run under; [] when they can't be
    # resolved.
    def llm_context_layers(args)
      LLMContextStrategy.resolve(target, names: names, **args).active_layers
    rescue StandardError => e
      unresolved(:llm_context_unresolved, e, [])
    end

    # models:/hosts: window_tokens (ContextWindow.setting), nil when unset.
    def window_setting
      ContextWindow.setting(target, names: names)
    rescue StandardError => e
      unresolved(:window_unresolved, e, nil)
    end

    # The window as its loop would see it (ChatLoop#context_window: a remote
    # chat host has no /props, only its model list); nil when it can't be
    # resolved.
    def context_window
      client = self.client
      adapter = nil
      if entry.chat?
        adapter = registry.adapter_for(entry)
        client = nil if adapter.remote?
      end
      ContextWindow.resolve(client: client, model: bare, adapter: adapter, setting: ContextWindow.setting(target, names: names))
    rescue StandardError => e
      unresolved(:window_unresolved, e, nil)
    end

    # Its price on its host (hosts.<name>.models.<id>.price), by the id
    # asked for, never the one served; nil when none.
    def price
      entry.models&.dig(bare.to_s.strip.downcase)&.price
    rescue StandardError => e
      unresolved(:price_unresolved, e, nil)
    end

    # [served, +asked+] from llama.cpp's /props (one short cached probe),
    # [nil, nil] for a remote chat host, without an answer, or when it
    # can't be asked.
    def served_from_props(asked)
      if entry.chat? && registry.adapter_for(entry).remote?
        return [nil, nil]
      end

      served = ServedModel.from_props(client.server_props(model: bare))
      served ? [served, asked] : [nil, nil]
    rescue StandardError => e
      # The model resolved; asking its server failed (its /props, its adapter).
      unresolved(:served_probe_failed, e, [nil, nil])
    end

    # The host whose hosts.<name>.models.<id>.served names +served+
    # (ServedModel.expected_by), nil when none does.
    def served_expected_by(served)
      ServedModel.expected_by(target, served)
    rescue StandardError => e
      unresolved(:served_unresolved, e, nil)
    end

    # What a local native host's cached /props names when it isn't the
    # model asked for; nil for a chat or remote host, or before any probe.
    def prompt_served
      return nil if entry.nil? || entry.chat? || entry.remote? || !client.respond_to?(:cached_server_props)

      served = ServedModel.from_props(client.cached_server_props(model: bare))
      served if ServedModel.differs?(bare, served)
    rescue StandardError => e
      unresolved(:served_unresolved, e, nil)
    end

    # Whether it sees images (VisionSupport.for) under +profile+.
    def vision_support(profile)
      VisionSupport.for(target, profile: profile, adapter: vision_adapter, names: names)
    end

    # A chat host's adapter (what it says of images), nil on a native host.
    def vision_adapter
      entry.chat? ? registry.adapter_for(entry) : nil
    rescue StandardError => e
      unresolved(:vision_adapter_unresolved, e, nil)
    end

    # Which prompt profile it gets (ModelProfile.resolve: may probe /props).
    # Not cached here. Raises.
    # @return [ModelProfile::Resolution]
    def profile_resolution
      ModelProfile.resolve(names: names, entry: entry, client: client, bare_model: bare)
    end

    # See Unresolved.fallback.
    def unresolved(event, error, value) = EffectiveModel::Unresolved.fallback(event, self, error, value)
    private :unresolved

    # The name, typed name and host only: the default would print the
    # registry and the client into any error message.
    def inspect = "#<Samagotchi::EffectiveModel #{name.inspect} typed=#{typed.inspect} host=#{entry&.name.inspect}>"
    alias_method :to_s, :inspect
  end

  class EffectiveModel
    # The fallback an effective model's reader gives when its setting
    # can't be resolved.
    module Unresolved
      module_function

      # @param event [Symbol] the log event (<setting>_unresolved)
      # @param model [EffectiveModel, String] the model (or its name)
      # @param error [StandardError]
      # @return +value+
      def fallback(_event, _model, _error, value) = value
    end
  end
end
