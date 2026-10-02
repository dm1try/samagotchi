# frozen_string_literal: true

require_relative "log"
module Samagotchi
  # Encapsulates all model-specific token formats and parsing behavior.
  # Each profile maps to a model family; ModelProfile.resolve picks one
  # (config, the server's chat template, the name, then qwen36).
  #
  # Current profiles:
  #   qwen36  — Qwen 3.6 chat template with function calling (the default)
  #   gemma4  — Gemma 4 format
  class ModelProfile
    MODEL_ENV = "SAMAGOTCHI_DEFAULT_MODEL"
    # No model anywhere (--model, default.model in config.yml, the env): a
    # first run before any config. An ArgumentError, as before.
    MissingModel = Class.new(ArgumentError)
    # A host-qualified model whose host isn't configured (a MissingModel,
    # so every surface that reports a missing model reports it the same way).
    UnknownHost = Class.new(MissingModel)

    attr_reader :name, :turn_start, :turn_end,
                :tool_call_open, :tool_call_close,
                :tool_response_open, :tool_response_close,
                :string_delim,
                :thought_open, :thought_close,
                :system_prefix, :user_prefix, :assistant_prefix,
                :model_prefix,
                :stop_sequences, :tool_decl_format,
                :image_template

    def initialize(config)
      @name = config[:name]
      @turn_start = config[:turn_start]
      @turn_end = config[:turn_end]
      @tool_call_open = config[:tool_call_open]
      @tool_call_close = config[:tool_call_close]
      @tool_response_open = config[:tool_response_open]
      @tool_response_close = config[:tool_response_close]
      @string_delim = config[:string_delim]
      @thought_open = config[:thought_open]
      @thought_close = config[:thought_close]
      @system_prefix = config[:system_prefix]
      @user_prefix = config[:user_prefix]
      @assistant_prefix = config[:assistant_prefix]
      @model_prefix = config[:model_prefix]
      @stop_sequences = config[:stop_sequences]
      @tool_decl_format = config[:tool_decl_format]
      # How the chat template wraps an image's media marker ("%{marker}"),
      # or nil when chi doesn't know it yet (native images are refused).
      @image_template = config[:image_template]
    end

    # The token the image template opens with, e.g. "<|vision_start|>": the
    # server's chat template must use it too (VisionSupport).
    def image_open_token
      image_template&.split("%{marker}")&.first.to_s
    end

    def self.gemma4
      new(
        name: "gemma4",
        turn_start: "<|turn>",
        turn_end: "<end_of_turn>",
        tool_call_open: "<|tool_call>",
        tool_call_close: "<tool_call|>",
        tool_response_open: "<|tool_response>",
        tool_response_close: "<tool_response|>",
        string_delim: '<|"|>',
        thought_open: "<|think|>",
        thought_close: nil,
        system_prefix: "",
        user_prefix: "",
        assistant_prefix: "",
        model_prefix: "",
        stop_sequences: ["<end_of_turn>", "<|tool_response>"],
        tool_decl_format: :gemma4
      )
    end

    def self.qwen36
      new(
        name: "qwen36",
        turn_start: "",
        turn_end: "",
        tool_call_open: "<tool_call>",
        tool_call_close: "</tool_call>",
        tool_response_open: "<tool_response>",
        tool_response_close: "</tool_response>",
        string_delim: nil,
        thought_open: "<think>",
        thought_close: "</think>",
        system_prefix: "<|im_start|>system\n",
        user_prefix: "<|im_start|>user\n",
        assistant_prefix: "<|im_start|>assistant\n",
        model_prefix: "<|im_start|>assistant\n",
        stop_sequences: ["<|im_end|>"],
        tool_decl_format: :qwen36,
        image_template: "<|vision_start|>%{marker}<|vision_end|>"
      )
    end

    def self.default
      gemma4
    end

    def self.normalize(value)
      return value if value.is_a?(self)

      case value.to_s.strip.downcase
      when "qwen", "qwen3", "qwen36", "qwen3.6"
        qwen36
      when "gemma", "gemma4", "gemma4o"
        gemma4
      else
        gemma4
      end
    end

    def self.required_model_name(model_name = nil)
      value = model_name.to_s.strip
      if value.empty?
        require_relative "config"
        value = Samagotchi::Config.get("default.model").to_s.strip
      end
      raise MissingModel, missing_model_message if value.empty?

      value
    end

    # Raises UnknownHost when +model_name+ (or the alias it names) is
    # qualified with a host that isn't configured, instead of sending the
    # whole ref to the default host as a model id, and when an alias after
    # a host prefix names another host ("openrouter:tiny" with tiny:
    # box:…), or with a host config.yml has with enabled: false. Where a
    # model comes in (an Engine starting or switching, a spawned session)
    # calls it.
    # @param hosts [Hash, nil] the hosts a prefix may name (a HostRegistry's
    #   entries); config.yml's by default
    # @return [String] +model_name+
    def self.check_host!(model_name, env: ENV, hosts: nil)
      require_relative "config"
      hosts ||= Samagotchi::ConfigFile.hosts_config(env: env)
      parsed = Samagotchi::ConfigFile.model_ref(model_name, env: env, hosts: hosts)
      if (other = parsed.host_conflict)
        raise UnknownHost, "alias '#{parsed.alias_name}' names host '#{other}', not '#{parsed.host_name}'; " \
                           "use #{parsed.alias_name} or #{other}:#{parsed.alias_name}"
      end
      ref = parsed.ref
      if !parsed.host_name && (disabled = disabled_host_prefix(ref, hosts, env))
        raise UnknownHost, "host '#{disabled}' is disabled (enabled: false in config.yml)"
      end
      warn_host_slash(ref, hosts) unless parsed.host_name
      host = Samagotchi::ConfigFile.unknown_host_prefix(ref, hosts: hosts)
      return model_name unless host

      names = hosts.keys.map { |k| k.to_s.downcase }.sort
      near = Samagotchi::Config.near_names(host, names).first(3)
      hint = near.empty? ? "" : " (did you mean #{near.map { |n| "'#{n}'" }.join(' or ')}?)"
      raise UnknownHost, "unknown host '#{host}' in model '#{ref}'#{hint}; the configured hosts are #{names.join(', ')}"
    end

    # The prefix of "box:x" when box is a host config.yml has with
    # enabled: false (left out of +hosts+), else nil.
    def self.disabled_host_prefix(ref, hosts, env)
      prefix, rest = ref.to_s.split(":", 2)
      return nil if rest.to_s.strip.empty?

      prefix = prefix.strip.downcase
      return nil if hosts.keys.any? { |k| k.to_s.downcase == prefix }

      raw = Samagotchi::ConfigFile.read_yaml(env: env)
      raw = raw[Samagotchi::ConfigFile::HOSTS_KEY] if raw.is_a?(Hash)
      return nil unless raw.is_a?(Hash)

      cfg = raw.find { |name, _| name.to_s.strip.downcase == prefix }&.last
      return nil unless cfg.is_a?(Hash)

      enabled = cfg.key?("enabled") ? cfg["enabled"] : cfg[:enabled]
      enabled == false || enabled.to_s.strip.downcase == "false" ? prefix : nil
    end

    # "box/x" named host box until '/' stopped naming a host: a saved
    # session or a hand-written ref says so once, then goes to the default host.
    def self.warn_host_slash(ref, hosts)
      prefix, rest = ref.to_s.split("/", 2)
      return if rest.to_s.empty? || !hosts.keys.map { |k| k.to_s.downcase }.include?(prefix.downcase)

      Samagotchi::ConfigFile.warn_once("Warning: model '#{ref}' starts with the host '#{prefix}' and '/': only ':' names a host now, " \
                                       "so it goes to the default host as written; use #{prefix}:#{rest} (/model #{prefix}:#{rest})")
    end
    private_class_method :warn_host_slash

    # One line for the user: where to set the model.
    def self.missing_model_message
      path = begin
        require_relative "config"
        Samagotchi::ConfigFile.global_path
      rescue StandardError, LoadError
        "~/.config/samagotchi/config.yml"
      end
      "no model configured: set default.model in #{path} to the model id your server serves " \
        "(or #{MODEL_ENV}, or pass --model ID); see docs/configuration.md; or run: chi bootstrap HOST[:PORT]"
    end

    def self.from_model_name(model_name)
      named(inferred_profile_name(model_name))
    end

    # qwen → qwen36, gemma → gemma4, anything else → DEFAULT_NAME: many
    # models with other names are Qwen-based, and under the gemma4 profile a
    # ChatML model never hits a stop sequence.
    def self.inferred_profile_name(model_name)
      normalized = model_name.to_s.strip.downcase
      return "qwen36" if normalized.include?("qwen")
      return "gemma4" if normalized.include?("gemma")

      DEFAULT_NAME
    end

    def self.from_env
      from_model_name(required_model_name(nil))
    end

    # ── Resolution: which profile a model gets ───────────────────────────

    NAMES = %w[qwen36 gemma4].freeze

    # The last layer, when nothing else says.
    DEFAULT_NAME = "qwen36"

    # What the server's chat template must contain for each profile. The
    # template tells the families apart where eos_token doesn't (Gemma 4's is
    # <eos> or <turn|>, depending on who packed it). llama.cpp itself detects
    # Gemma 4 by '<|tool_call>call:'.
    FINGERPRINTS = {
      "qwen36" => ["<|im_start|>", "<function="],
      "gemma4" => ["<|turn>", "<|tool_call>"]
    }.freeze

    # A resolved profile and where it came from. source: :cli, :env,
    # :config, :server, :name or :default; detail: the config key, the
    # template evidence or the matched name. retry: the server probe failed
    # (unreachable, or loading and answering 503), so the caller should
    # resolve again before its next turn.
    Resolution = Data.define(:profile, :source, :detail, :retry) do
      def retry? = self.retry

      # How /stats, /model and chi self name the source.
      def label
        case source
        when :config then "config (#{detail})"
        when :server then "server (chat_template)"
        else source.to_s
        end
      end
    end

    # The profile called +value+, or nil (unlike .normalize, which always
    # gives one).
    def self.named(value)
      name = value.to_s.strip.downcase
      NAMES.include?(name) ? public_send(name) : nil
    end

    # [profile name, evidence] from a llama.cpp /props body, or nil when its
    # chat template says neither family. A ChatML template without Qwen's
    # <function= calls (older Qwen3, Hermes, ...) still gets qwen36: its
    # <|im_end|> stops generation, where gemma4's stop sequences never occur.
    def self.fingerprint(props)
      template = props.is_a?(Hash) ? props["chat_template"].to_s : ""
      FINGERPRINTS.each do |name, markers|
        return [name, markers.join(" + ")] if markers.all? { |marker| template.include?(marker) }
      end
      return ["qwen36", "ChatML"] if template.include?("<|im_start|>")

      nil
    end

    # Which profile a model gets, first match wins:
    #   1. override: --profile / SAMAGOTCHI_MODEL_PROFILE ([value, origin];
    #      a nil value is not set, whatever its origin)
    #   2. models: in the config file, under any of +names+
    #   3. hosts.<name>.profile of +entry+
    #   4. the server's chat template (native llama.cpp hosts only)
    #   5. the name: qwen → qwen36, gemma → gemma4
    #   6. DEFAULT_NAME
    # An unknown configured value warns and is skipped.
    #
    # @param names [Array<String>] the model as typed, alias-resolved, bare
    # @param entry [HostRegistry::HostEntry, nil] the model's host
    # @param client [#server_props, nil] the host's client (nil: no probe)
    # @param bare_model [String, nil] the name the probe asks the server about
    # @return [Resolution]
    def self.resolve(names:, entry:, client:, bare_model:, override: nil, models: nil)
      require_relative "config"
      override ||= Samagotchi::Config.get_with_origin("model.profile")
      models ||= Samagotchi::ConfigFile.model_settings
      names = Array(names).map { |n| n.to_s.strip }.reject(&:empty?).uniq

      value, origin = override
      if (profile = named(value))
        return Resolution.new(profile: profile, source: origin == :env ? :env : :cli, detail: nil, retry: false)
      end

      names.map(&:downcase).uniq.each do |key|
        setting = models[key]
        next unless setting && setting[:profile]

        profile = configured(setting[:profile], "models: #{key}")
        return Resolution.new(profile: profile, source: :config, detail: "models: #{key}", retry: false) if profile
      end

      if entry&.profile && (profile = configured(entry.profile, "hosts.#{entry.name}"))
        return Resolution.new(profile: profile, source: :config, detail: "hosts.#{entry.name}", retry: false)
      end

      retry_later = false
      if probe?(entry, client)
        props = client.server_props(model: bare_model)
        if props && !props.answered?
          retry_later = true
        elsif props && (found = fingerprint(props.body))
          return Resolution.new(profile: named(found[0]), source: :server, detail: found[1], retry: false)
        end
      end

      names.each do |name|
        lowered = name.downcase
        family = if lowered.include?("qwen") then "qwen36"
                 elsif lowered.include?("gemma") then "gemma4"
                 end
        return Resolution.new(profile: named(family), source: :name, detail: name, retry: retry_later) if family
      end

      Resolution.new(profile: named(DEFAULT_NAME), source: :default, detail: nil, retry: retry_later)
    end

    def self.configured(value, where)
      profile = named(value)
      Log.warn(:config, "unknown_profile", echo: "Warning: unknown profile #{value.to_s.inspect} in #{where} (allowed: #{NAMES.join(', ')}) — ignored", profile: value.to_s, where: where) unless profile
      profile
    end
    private_class_method :configured

    # Only a native llama.cpp host has /props with a chat template; a chat
    # host (api: openai) barely uses a profile, and mlx/oMLX expose none.
    def self.probe?(entry, client)
      return false if client.nil? || !client.respond_to?(:server_props)
      return false if entry&.chat?

      client.transport.name == :llama_cpp
    end
    private_class_method :probe?

    def uses_role_prefixes?
      !system_prefix.empty? && !user_prefix.empty?
    end
  end
end
