# frozen_string_literal: true

require_relative "config"
require_relative "setting_explained"
require_relative "llm/anthropic_wire"

module Samagotchi
  # Which of its own reasoning a chat host's model gets back
  # (LLM::ChatLoop sends it as reasoning_content on its earlier replies):
  #
  #   turn  the running turn's replies only (since the turn's start; a
  #         steer, a plugin's nudge or a Continue's text merged into the
  #         turn doesn't reset it, as on a native host: .run_start)
  #   drop  none
  #   all   every reply that has reasoning, earlier turns too (a direct
  #         DeepSeek API with tools wants this)
  #
  # Order (#resolve): the session's own level (/reasoning-history), then
  # SAMAGOTCHI_REASONING_HISTORY, models.<key>.reasoning_history,
  # hosts.<name>.reasoning_history, then the host's api default: all for
  # api: anthropic (its thinking blocks go back verbatim, and removing
  # earlier turns' would rewrite the cached prefix every turn; ChatLoop
  # floors drop at turn there), turn elsewhere. Native hosts ignore it:
  # KernelLoop keeps the running turn's reasoning on its own, from the
  # run's start (.run_start).
  module ReasoningHistory
    LEVELS = %i[drop turn all].freeze
    DEFAULT = :turn
    # The default for a host's api when it isn't DEFAULT.
    API_DEFAULTS = { anthropic: :all }.freeze
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

      [API_DEFAULTS.fetch(target.entry&.api&.to_sym, DEFAULT), nil]
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
    # sends back as reasoning_content; LLM::ChatLoop#thought?), or with a
    # saved thinking block (a Messages host's, which may carry no text:
    # Claude's omitted display).
    def earlier_thought?(conversation)
      Array(conversation).any? do |entry|
        next false unless entry[:role].to_s == "model"

        (entry[:thinking].is_a?(String) && !entry[:thinking].strip.empty?) ||
          Array(entry[:anthropic_content]).any? { |block| LLM::AnthropicWire.thinking_block?(block) }
      end
    end

    # Where a run's own reasoning starts in +messages+: its start (+since+;
    # nil without one). Inside one run nothing re-sanitizes, so an entry the
    # run merged (a steer, a delegate report, the Qwen recovery prompt) left
    # the reasoning before it in the prompt: it stays. Only a user or
    # turn_start entry added after the run ended (after its last model
    # message: a !cmd's output) starts it again past itself.
    # @param messages [Array<Hash>] the conversation
    # @param since [Integer, nil] the run's start
    # @return [Integer, nil]
    def run_start(messages, since)
      return nil if since.nil?

      last_reply = messages.rindex { |m| m[:role].to_s == "model" } || -1
      query = messages.rindex { |m| m[:role].to_s == "user" || m[:turn_start] == true }
      query && query > last_reply ? [query + 1, since].max : since
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
