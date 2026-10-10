# frozen_string_literal: true

require_relative "config"

module Samagotchi
  # How much a model thinks: one level per model, host or run, mapped to each
  # backend's own switch. The one place that knows the mapping.
  #
  #   off      thinking off where the backend can do it
  #   low, medium, high   the effort a chat host is asked for
  #   default  chi sends nothing: the provider's or template's own default
  #
  # Order (#resolve): the session's own level (/thinking, chi --thinking at
  # start, chi send --new --thinking, the web), then the process default
  # (chi web --thinking / SAMAGOTCHI_THINKING_LEVEL), then
  # models.<key>.thinking, hosts.<name>.thinking, thinking.level in
  # config.yml, then default.
  module Thinking
    LEVELS = %i[off low medium high default].freeze
    EFFORTS = %i[low medium high].freeze
    DEFAULT = :default

    # Gemma 4 turns thinking on with this token at the start of the system prompt.
    GEMMA_THINK_TOKEN = "<|think|>\n"
    # An empty thought after the Qwen assistant cue: the model answers at once
    # (what the server's own template does with enable_thinking false).
    QWEN_EMPTY_THOUGHT = "<think>\n\n</think>\n\n"
    # Gemma 4's empty thought channel after the model cue, as its chat
    # template writes it with enable_thinking false (only where a model turn
    # starts: Prompt.prefill_for).
    GEMMA_EMPTY_THOUGHT = "<|channel>thought\n<channel|>"

    # What a native prompt gets for a level: the text before the system
    # prompt, the text after the assistant cue, and whether the level means
    # anything there (low/medium/high have no native knob).
    Native = Data.define(:system_token, :prefill, :honoured)

    # The source a session's own level reads as.
    SESSION_SOURCE = "session"

    # A level and where it came from (#explain): +source+ is "session",
    # "--thinking", "SAMAGOTCHI_THINKING_LEVEL", "models: qwen",
    # "hosts.work" or "thinking.level", nil for the default; +own+ is the
    # session's own level, nil without one. What /thinking, /model,
    # /stats, the snapshots and the web read.
    Explained = Data.define(:level, :source, :own) do
      # "low (session)", "default" with no source.
      def label = source ? "#{level} (#{source})" : level.to_s

      # The plain form the snapshots, the worker's command_ran event and
      # the web read.
      # @return [Hash] symbol keys
      def summary = { level: level.to_s, source: source, own: own&.to_s }
    end

    module_function

    # A session's own level from its file or a command word: :off, :low,
    # :medium or :high; nil for anything else, default included (unset:
    # the session follows the process default and the model). Never warns:
    # a session file keeps a value it can't read as written.
    # @return [Symbol, nil]
    def session_level(value)
      return value if LEVELS.include?(value) && value != DEFAULT
      return nil unless value.is_a?(String)

      level = value.strip.downcase.to_sym
      LEVELS.include?(level) && level != DEFAULT ? level : nil
    end

    # A configured value as a level; nil when unset or not a level (that
    # warns once, naming +where+). YAML reads an unquoted `off` as false,
    # which is :off; true (`on`) isn't a level.
    # @return [Symbol, nil]
    def level(value, where)
      return nil if value.nil?
      return :off if value == false || value.to_s.strip.downcase == "false"

      text = value.to_s.strip.downcase
      return text.to_sym if LEVELS.include?(text.to_sym)

      hint = value == true || %w[true on].include?(text) ? "; `on` isn't one, `default` leaves it to the model" : ""
      ConfigFile.warn_once "Warning: #{where}: thinking must be one of #{LEVELS.join(", ")}#{hint}; ignored"
      nil
    end

    # The level for +target+ and where it came from ("session",
    # "--thinking", "models: qwen", "hosts.work", "thinking.level"; nil for
    # the default).
    # @param target [HostRegistry::ModelTarget]
    # @param names [Array<String>] the model's lookup names (HostRegistry#lookup_names)
    # @param models [Hash{String => ModelSettings}, nil] ConfigFile.model_settings (specs)
    # @param session [Symbol, nil] the session's own level (Session#thinking)
    # @return [Array(Symbol, String|nil)]
    def resolve(target, names:, models: nil, session: nil)
      return [session, SESSION_SOURCE] if session

      global, origin = global_level
      return [global, origin == :cli ? "--thinking" : "SAMAGOTCHI_THINKING_LEVEL"] if global && %i[cli env].include?(origin)

      models ||= begin
        ConfigFile.model_settings
      rescue StandardError
        {}
      end
      setting = ConfigFile.model_setting(names, :thinking, models: models)
      return [setting.value, "models: #{setting.key}"] if setting

      host = target.entry.thinking
      return [host, "hosts.#{target.entry.name}"] if host
      return [global, "thinking.level"] if global

      [DEFAULT, nil]
    end

    # #resolve, as an Explained with the session's own level beside it.
    # @return [Explained]
    def explain(target, names:, models: nil, session: nil)
      level, source = resolve(target, names: names, models: models, session: session)
      Explained.new(level: level, source: source, own: session)
    end

    # thinking.level as a level and its origin (:cli, :env, :file), or nil.
    def global_level
      raw, origin = Config.get_with_origin("thinking.level")
      return nil if origin == :default

      where = { cli: "--thinking", env: "SAMAGOTCHI_THINKING_LEVEL" }.fetch(origin, "thinking.level")
      value = level(raw, where)
      value ? [value, origin] : nil
    rescue StandardError
      nil
    end

    # Request fields for an OpenAI-style chat host. off sends both switches
    # (the template's enable_thinking and the OpenAI-style reasoning_effort
    # "none"): llama.cpp, Splash and OpenRouter each honour one of them.
    # An effort goes as reasoning_effort (llama.cpp ignores it). default
    # sends nothing.
    # @return [Hash] frozen
    def chat_fields(level)
      case level
      when :off then { chat_template_kwargs: { enable_thinking: false }.freeze, reasoning_effort: "none" }.freeze
      when *EFFORTS then { reasoning_effort: level.to_s }.freeze
      else {}.freeze
      end
    end

    # Whether a chat host's /props (+props+, Client::ServerProps) says its
    # chat template takes no effort (llama.cpp's
    # chat_template_caps.supports_reasoning_effort: false), so +level+'s
    # reasoning_effort is ignored. false when it doesn't say.
    def effort_ignored?(level, props)
      return false unless EFFORTS.include?(level) && props&.answered? && props.body.is_a?(Hash)

      caps = props.body["chat_template_caps"]
      caps.is_a?(Hash) && caps["supports_reasoning_effort"] == false
    end

    # The native prompt's switch for +level+ under +profile+.
    # @param profile [ModelProfile]
    # @return [Native]
    def native(level, profile)
      off = level == :off
      honoured = !EFFORTS.include?(level)
      case profile&.name
      when "gemma4" then Native.new(system_token: off ? "" : GEMMA_THINK_TOKEN, prefill: off ? GEMMA_EMPTY_THOUGHT : "", honoured: honoured)
      when "qwen36" then Native.new(system_token: "", prefill: off ? QWEN_EMPTY_THOUGHT : "", honoured: honoured)
      else Native.new(system_token: "", prefill: "", honoured: level == DEFAULT)
      end
    end
  end
end
