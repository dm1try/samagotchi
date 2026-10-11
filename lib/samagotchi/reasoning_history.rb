# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # Which of its own reasoning a chat host's model gets back
  # (LLM::ChatLoop sends it as reasoning_content on its earlier replies):
  #
  #   turn  the running turn's replies only (the tool-call rounds since the
  #         last user message); what Qwen's, Gemma 4's and DeepSeek's
  #         templates and the hosted APIs expect
  #   drop  none
  #   all   every reply that has reasoning, earlier turns too (a direct
  #         DeepSeek API with tools wants this)
  #
  # Order (#resolve): SAMAGOTCHI_REASONING_HISTORY, then
  # models.<key>.reasoning_history, hosts.<name>.reasoning_history, then
  # turn. Native hosts ignore it: KernelLoop keeps the running turn's
  # reasoning on its own.
  module ReasoningHistory
    LEVELS = %i[drop turn all].freeze
    DEFAULT = :turn
    KEY = "reasoning_history"
    ENV_NAME = "SAMAGOTCHI_REASONING_HISTORY"

    module_function

    # A configured value as a level; nil when unset or not a level (that
    # warns once, naming +where+).
    # @return [Symbol, nil]
    def level(value, where)
      return nil if value.nil?

      text = value.to_s.strip.downcase
      return text.to_sym if LEVELS.include?(text.to_sym)

      ConfigFile.warn_once "Warning: #{where}: #{KEY} must be one of #{LEVELS.join(", ")}; ignored"
      nil
    end

    # The level for +target+ and where it came from
    # ("SAMAGOTCHI_REASONING_HISTORY", "models: qwen", "hosts.work"; nil for
    # the default).
    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>] the model's lookup names (HostRegistry#lookup_names)
    # @param models [Hash{String => ModelSettings}, nil] ConfigFile.model_settings (specs)
    # @return [Array(Symbol, String|nil)]
    def resolve(target, names:, models: nil)
      env = env_level
      return [env, ENV_NAME] if env

      models ||= begin
        ConfigFile.model_settings
      rescue StandardError
        {}
      end
      setting = ConfigFile.model_setting(names, :reasoning_history, models: models)
      return [setting.value, "models: #{setting.key}"] if setting

      host = target.entry&.reasoning_history
      return [host, "hosts.#{target.entry.name}"] if host

      [DEFAULT, nil]
    end

    # "drop (models: qwen)", "turn (default)".
    def label(level, source) = "#{level} (#{source || "default"})"

    # SAMAGOTCHI_REASONING_HISTORY as a level, nil when unset or unknown.
    def env_level
      raw, origin = Config.get_with_origin(KEY)
      origin == :env ? level(raw, ENV_NAME) : nil
    rescue StandardError
      nil
    end
  end
end
