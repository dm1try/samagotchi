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
    # Set beside MODEL_ENV for a worker spawned by a `chi --model X`: X is
    # that run's default, not one its commands' chi should inherit
    # (SessionManager.spawn_options, Tools::Builtins.parent_env).
    MODEL_FROM_CLI_ENV = "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI"
    # No model anywhere (--model, default.model in config.yml, the env): a
    # first run before any config. An ArgumentError, as before.
    class MissingModel < ArgumentError
    end

    # A host-qualified model whose host isn't configured (a MissingModel,
    # so every surface that reports a missing model reports it the same way).
    class UnknownHost < MissingModel
    end

    # Gemma 4 thinks in a channel: `<|channel>thought` … `<channel|>`. The
    # one source for the parser, the stream splitter, the literal guard and
    # the web's saved-message reader.
    GEMMA_THOUGHT_CHANNEL_OPEN = "<|channel>thought"
    GEMMA_THOUGHT_CHANNEL_CLOSE = "<channel|>"

    attr_reader :name, :turn_start, :turn_end,
                :tool_call_open, :tool_call_close,
                :tool_response_open, :tool_response_close,
                :string_delim,
                :thought_open, :thought_close,
                :thought_channel_open, :thought_channel_close,
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
      # A thinking block besides thought_open's (Gemma's channel), or nil.
      @thought_channel_open = config[:thought_channel_open]
      @thought_channel_close = config[:thought_channel_close]
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
        turn_end: "<turn|>",
        tool_call_open: "<|tool_call>",
        tool_call_close: "<tool_call|>",
        tool_response_open: "<|tool_response>",
        tool_response_close: "<tool_response|>",
        string_delim: '<|"|>',
        thought_open: "<|think|>",
        thought_close: nil,
        thought_channel_open: GEMMA_THOUGHT_CHANNEL_OPEN,
        thought_channel_close: GEMMA_THOUGHT_CHANNEL_CLOSE,
        system_prefix: "",
        user_prefix: "",
        assistant_prefix: "",
        model_prefix: "",
        stop_sequences: ["<turn|>", "<|tool_response>"],
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
      named(DEFAULT_NAME)
    end

    def self.normalize(value)
      return value if value.is_a?(self)

      case value.to_s.strip.downcase
      when "qwen", "qwen3", "qwen36", "qwen3.6"
        qwen36
      when "gemma", "gemma4", "gemma4o"
        gemma4
      else
        named(DEFAULT_NAME)
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
      hint = near.empty? ? "" : " (did you mean #{near.map { |n| "'#{n}'" }.join(" or ")}?)"
      raise UnknownHost, "unknown host '#{host}' in model '#{ref}'#{hint}; the configured hosts are #{names.join(", ")}"
    end

    # A warning when +model_name+ resolves to a model id a host's saved
    # list doesn't have (ModelListStore: what a `chi models`, a /models or
    # the web's GET /api/models last listed for that host), else nil.
    # Called where a session is spawned without listing the hosts itself
    # (`chi send --new --model`, the delegate tool), so a typo is
    # named before the worker's first turn fails on it. Only a warning: some
    # hosts serve ids they don't list (a one-model llama.cpp server takes any
    # name, OpenRouter's :nitro variants), so the session starts anyway.
    #
    # Only a ref that names a host is checked (its alias resolved first, as
    # ModelRef.parse does), and only against that host's own list: a bare id
    # goes to whichever host lists it (HostRegistry#host_for_model), so no
    # single list can judge it. Nothing is checked either without a saved
    # list for the host or with one older than ModelListStore::TTL_SECONDS
    # (a week: the host may serve different models by now).
    #
    # A saved list that lacks the id may itself be stale by content: a
    # one-model server was reloaded with another model while the list still
    # names the old one. So a miss in a saved list older than
    # RELIST_AFTER_SECONDS re-lists that one host once, judges again against
    # what it lists now, and lets the saved list take the re-list's ids (the
    # default re-list saves them too). A younger saved list, a hit, no list,
    # a stale list (TTL_SECONDS) or a ref that names no host never asks a
    # host; a re-list that fails, times out (RE_LIST_TIMEOUT_SECONDS) or
    # lists nothing warns from the saved list (a host that is down is no
    # evidence either way).
    # @param hosts [Hash, nil] the hosts a prefix may name (a HostRegistry's
    #   entries); config.yml's by default
    # @param lists [#read] ModelListStore by default
    # @param relist [#call, nil] how a miss re-lists the host:
    #   (host_name, env) -> ids or nil. HostRegistry#list_models by default.
    # @return [String, nil]
    def self.model_warning(model_name, env: ENV, hosts: nil, lists: nil, relist: nil)
      require_relative "config"
      require_relative "model_list_store"
      hosts ||= Samagotchi::ConfigFile.hosts_config(env: env)
      lists ||= Samagotchi::ModelListStore
      parsed = Samagotchi::ConfigFile.model_ref(model_name, env: env, hosts: hosts)
      host = parsed.host_name
      return nil unless host

      list = lists.read(env: env)[host.to_s.strip.downcase]
      return nil if list.nil? || list.stale? || list.known?(parsed.id)
      # A saved list this recent is taken at its word. Re-listing every miss
      # would make each launch of an id a host serves but never lists (a
      # gateway's round-robin aliases) pay the re-list's cap and warn
      # anyway; a list that old is the case worth catching (a one-model
      # server reloaded with another model).
      return unknown_model_message(parsed.id, host, list.ids) if list.age < RELIST_AFTER_SECONDS

      fresh_ids = relist_or_nil(relist || default_relist(hosts), host, env)
      # A re-list that answered: the saved list catches up (the default
      # re-list, HostRegistry#list_models, saved it already).
      if fresh_ids
        Samagotchi::ModelListStore.save(host, fresh_ids, env: env)
        return nil if fresh_ids.any? { |id| id.to_s.casecmp?(parsed.id.to_s.strip) }

        return unknown_model_message(parsed.id, host, fresh_ids)
      end

      # No answer (failed, timed out, listed nothing): the saved list stands.
      unknown_model_message(parsed.id, host, list.ids)
    end

    # How long a miss's re-list may take before it is treated as failed: a
    # spawn (`chi send --new --model`, delegate) warns from the saved list
    # then, rather than wait on a slow host.
    RE_LIST_TIMEOUT_SECONDS = 5

    # A saved list younger than this is not re-listed on a miss (the other
    # way it can be wrong: stale by CONTENT within its TTL, a one-model
    # server reloaded with another model). A host that serves ids it never
    # lists (a gateway's round-robin aliases) would otherwise pay the
    # re-list's cap on every launch.
    RELIST_AFTER_SECONDS = 10 * 60

    # The default re-list: one HostRegistry, one host listed (and saved).
    # Bounded like `chi models`' `wait:`: a thread still listing at the cap
    # is left running and its answer ignored (only a short-lived spawn is
    # ever here).
    # @return [#call] (host_name, env) -> ids or nil
    def self.default_relist(hosts)
      lambda do |host_name, relist_env|
        require_relative "host_registry"
        registry = Samagotchi::HostRegistry.new(hosts_config: hosts, env: relist_env)
        answer = nil
        thread = Thread.new { answer = registry.list_models(host_name) }
        thread.join(RE_LIST_TIMEOUT_SECONDS)
        answer
      end
    end
    private_class_method :default_relist

    # The re-list's ids, or nil when it fails, times out or lists nothing.
    # A failing re-list is no evidence either way: the caller warns from the
    # saved list.
    def self.relist_or_nil(relist, host, env)
      ids = relist.call(host, env)
      ids.respond_to?(:any?) && ids.any? ? ids : nil
    rescue StandardError
      nil
    end
    private_class_method :relist_or_nil

    # The warning for an id the host doesn't list, with up to three close
    # ids (Config.near_names) when there are any.
    def self.unknown_model_message(id, host, ids)
      near = Samagotchi::Config.near_names(id, ids).first(3)
      hint = near.empty? ? "" : " (did you mean: #{near.join(", ")}?)"
      "host '#{host}' doesn't list model '#{id}'#{hint}; started it anyway; `chi models` lists what the hosts serve"
    end

    # The prefix of "box:x" when box is a host config.yml has with
    # enabled: false (left out of +hosts+), else nil.
    def self.disabled_host_prefix(ref, hosts, env)
      prefix, rest = ref.to_s.split(":", 2)
      return nil if rest.to_s.strip.empty?

      prefix = prefix.strip.downcase
      return nil if hosts.keys.any? { |k| k.to_s.downcase == prefix }

      Samagotchi::ConfigFile.disabled_host_names(env: env).include?(prefix) ? prefix : nil
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
      return %w[qwen36 ChatML] if template.include?("<|im_start|>")

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
      Log.warn(:config, "unknown_profile", echo: "Warning: unknown profile #{value.to_s.inspect} in #{where} (allowed: #{NAMES.join(", ")}) — ignored", profile: value.to_s, where: where) unless profile
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
