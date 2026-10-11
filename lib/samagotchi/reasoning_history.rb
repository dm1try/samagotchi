# frozen_string_literal: true

require_relative "config"
require_relative "setting_explained"

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
  # Order (#resolve): the session's own level (/reasoning-history), then
  # SAMAGOTCHI_REASONING_HISTORY, models.<key>.reasoning_history,
  # hosts.<name>.reasoning_history, then turn. Native hosts ignore it:
  # KernelLoop keeps the running turn's reasoning on its own.
  module ReasoningHistory
    LEVELS = %i[drop turn all].freeze
    DEFAULT = :turn
    KEY = "reasoning_history"
    ENV_NAME = "SAMAGOTCHI_REASONING_HISTORY"
    # The source a session's own level reads as.
    SESSION_SOURCE = "session"
    # The word that unsets a session's own level.
    UNSET = "default"

    module_function

    # A session's own level from its file or a command word: :drop, :turn
    # or :all (an explicit turn is the session's own too); nil for anything
    # else, default included. Never warns: a session file keeps a value it
    # can't read as written.
    # @return [Symbol, nil]
    def session_level(value)
      return value if LEVELS.include?(value)
      return nil unless value.is_a?(String)

      level = value.strip.downcase.to_sym
      LEVELS.include?(level) ? level : nil
    end

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

    # The level for +target+ and where it came from ("session",
    # "SAMAGOTCHI_REASONING_HISTORY", "models: qwen", "hosts.work"; nil for
    # the default).
    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>] the model's lookup names (HostRegistry#lookup_names)
    # @param models [Hash{String => ModelSettings}, nil] ConfigFile.model_settings (specs)
    # @param session [Symbol, nil] the session's own level (Session#reasoning_history)
    # @return [Array(Symbol, String|nil)]
    def resolve(target, names:, models: nil, session: nil)
      return [session, SESSION_SOURCE] if session

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

    # #resolve, as a SettingExplained with the session's own level beside it.
    # @return [SettingExplained]
    def explain(target, names:, models: nil, session: nil)
      level, source = resolve(target, names: names, models: models, session: session)
      SettingExplained.new(level: level, source: source, own: session)
    end

    # What changing the level from +from+ to +to+ costs +target+'s prompt
    # cache, at a turn boundary (a change waits for the turn's end):
    #   :history  to or from all on a chat host, with an earlier model entry
    #             that has thinking: every earlier reply from there gains or
    #             loses its reasoning_content, so a server that renders it
    #             (hosted APIs; llama.cpp's default) reads the conversation
    #             again from the first earlier thought;
    #   nil       drop <-> turn (a turn's first request carries no reasoning
    #             under either), no change, nothing thought yet, or a
    #             native host (it ignores the level).
    # @param conversation [Array<Hash>] the session's messages
    # @return [Symbol, nil]
    def cache_cost(from, to, target:, conversation:)
      return nil unless target.entry&.chat?
      return nil if from == to || ![from, to].include?(:all)

      earlier_thought?(conversation) ? :history : nil
    end

    # Whether +conversation+ has a model entry with thinking (what all
    # sends back as reasoning_content; LLM::ChatLoop#thought?).
    def earlier_thought?(conversation)
      Array(conversation).any? do |entry|
        entry[:role].to_s == "model" && entry[:thinking].is_a?(String) && !entry[:thinking].strip.empty?
      end
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
