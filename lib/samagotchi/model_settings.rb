# frozen_string_literal: true

require_relative "config"
require_relative "llm_context_strategy"

module Samagotchi
  # One config.yml models: entry (per-model settings keyed by model id or
  # alias), parsed and checked; ConfigFile.model_settings holds them by
  # downcased key. Each field is nil when unset: profile kept as written
  # (downcased; ModelProfile.resolve validates it), vision true/false,
  # sampling a request-field map, thinking a level, window_tokens, and the
  # LLM context strategy, apply rule and budget (LLMContextStrategy). The
  # same per-model fields a hosts: entry carries (HostConfig).
  ModelSettings = Data.define(:profile, :vision, :sampling, :thinking, :window_tokens,
                              :llm_context_strategy, :llm_context_apply, :llm_context_budget_tokens) do
    # Every field may be left out (nil).
    def initialize(**fields)
      super(**members.to_h { |m| [m, nil] }, **fields)
    end

    # A models: entry as written, or nil when it is not a map (or the key is
    # blank). A bad value warns, naming the entry, and is left unset.
    # @param key [String] the downcased model id or alias
    # @param raw [Hash] string or symbol keys
    # @return [ModelSettings, nil]
    def self.parse(key, raw)
      return nil if key.to_s.empty? || !raw.is_a?(Hash)

      value = ->(name) { raw.key?(name.to_s) ? raw[name.to_s] : raw[name.to_sym] }
      where = "models: #{key}"
      profile = value.call(:profile).to_s.strip.downcase
      new(profile: profile.empty? ? nil : profile,
          vision: ConfigFile.vision_flag(value.call(:vision), where),
          sampling: ConfigFile.sampling_map(value.call(:sampling), where),
          thinking: Thinking.level(value.call(:thinking), where),
          window_tokens: ConfigFile.window_tokens(value.call(:window_tokens), where),
          llm_context_strategy: LLMContextStrategy.parse(value.call(LLMContextStrategy::KEY), where),
          llm_context_apply: LLMContextStrategy.parse_apply(value.call(LLMContextStrategy::APPLY_KEY), where),
          llm_context_budget_tokens: LLMContextStrategy.parse_budget(value.call(LLMContextStrategy::BUDGET_KEY), where))
    end
  end

  # One field ConfigFile.model_setting found: the models: key that set it
  # and its value.
  ModelSetting = Data.define(:key, :value)
end
