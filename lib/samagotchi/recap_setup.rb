# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "idle_recap"
require_relative "recap_store"

module Samagotchi
  # Builds (or disables) an Engine's idle recap job from the `recap:` kwarg
  # and the Config registry. Init-only: the Engine keeps the job it returns.
  module RecapSetup
    # Build (or disable) the idle recap job. On by default: with no recap
    # host or model configured it asks the session's current model on its
    # host, resolved at each attempt the way a turn does (a /model switch
    # counts). An explicit `recap: {host_ref:, model:}` or `{base_url:,
    # model:}` pins it; an incomplete one warns and leaves recap off.
    #
    # Single precedence path: explicit `recap:` kwarg > Config registry
    # (CLI > ENV > file > default). An explicit disable (`recap: false` as
    # the kwarg or in the config file, `recap: {enabled: false}`, or
    # SAMAGOTCHI_RECAP_ENABLED=false) always wins.
    #
    # @param recap          [Hash, false, nil] the Engine's `recap:` kwarg
    # @param engine         [Engine] the recap job's engine
    # @param host_registry  [HostRegistry]
    # @param session_target [#call] → the session's current model as a recap target
    # @param session_id     [#call] → String, nil
    # @param state_dir      [#call] → String
    # @return [IdleRecap, nil]
    def self.build(recap, engine:, host_registry:, session_target:, session_id:, state_dir:)
      return nil if recap == false
      # The TUI passes the config file's section; a worker passes nothing, so
      # read it here too (a scalar `recap: false` is only seen this way).
      return nil if recap.nil? && ConfigFile.recap_config == false
      return nil if Samagotchi::Config.get("recap.enabled") == false

      # Normalize kwarg (TerminalUI passes recap: recap_config hash or nil)
      kwarg_config = recap.is_a?(Hash) ? recap : {}

      base_url = string_config(kwarg_config, :base_url) || registry_string("recap.base_url")
      host_ref = string_config(kwarg_config, :host_ref) || string_config(kwarg_config, :host) || registry_string("recap.host_ref")
      model = string_config(kwarg_config, :model) || registry_string("recap.model")
      label = model

      target = nil
      if base_url.nil? && host_ref.nil? && model.nil?
        target = -> { session_target.call }
      else
        # If host_ref given, derive base_url (the host's OpenAI base) and its
        # API key variable from the host_registry entry
        api_key_env = nil
        if host_ref && !host_ref.empty?
          entry = host_registry.find_entry(host_ref)
          if entry
            base_url = entry.openai_base_url
            api_key_env = entry.api_key_env
            # If model is host-qualified, extract bare model for recap client
            _, bare = host_registry.parse_qualified_model(model) if model
            model = bare if bare && !bare.empty?
          else
            Log.warn(:recap, "host_ref_unknown", echo: "Warning: recap host_ref '#{host_ref}' not found in hosts:; recap disabled.", host_ref: host_ref)
            return nil
          end
        end

        if base_url.to_s.strip.empty? || model.to_s.strip.empty?
          Log.warn(:recap, "recap_unconfigured",
                   echo: "Warning: SAMAGOTCHI session recap is enabled but base_url/model are missing; recap disabled. " \
                         "Set recap: {host_ref:, model:} or SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL (or pass recap: {base_url:, model:}), " \
                         "or leave them all out to recap with the session's own model.")
          return nil
        end
        fixed = { base_url: base_url.to_s.strip, api_key_env: api_key_env, model: model.to_s.strip, label: label.to_s.strip }
        target = -> { fixed }
      end

      IdleRecap.new(
        engine: engine,
        target: target,
        inactivity: recap_number_setting(kwarg_config, :inactivity, "recap.inactivity", IdleRecap::DEFAULT_INACTIVITY_SECONDS, :float),
        min_user_turns: recap_number_setting(kwarg_config, :min_user_turns, "recap.min_user_turns", IdleRecap::DEFAULT_MIN_USER_TURNS, :int),
        timeout: recap_number_setting(kwarg_config, :timeout, "recap.timeout", IdleRecap::DEFAULT_TIMEOUT_SECONDS, :float),
        sentences: recap_sentences(string_config(kwarg_config, :sentences) || registry_string("recap.sentences")),
        store: RecapStore.new(session_id_lookup: -> { session_id.call }, state_dir_lookup: -> { state_dir.call })
      )
    end

    # recap.sentences as [min, max]; an invalid value warns and falls back to
    # the default range (the recap stays on).
    def self.recap_sentences(value)
      range = IdleRecap::RecapPrompt.sentences_range(value)
      return range if range

      default = IdleRecap::RecapPrompt::DEFAULT_SENTENCES
      Log.warn(:recap, "sentences_invalid", echo: "Warning: invalid value for recap.sentences: #{value.to_s.inspect} — using #{default.join('-')}",
                                            value: value.to_s)
      default
    end
    private_class_method :recap_sentences

    # Read a scalar recap setting via the Config registry (ENV > file > default).
    def self.registry_string(key)
      value = Samagotchi::Config.get(key)
      value = value.to_s.strip
      value.empty? ? nil : value
    rescue StandardError
      nil
    end
    private_class_method :registry_string

    # Resolve a numeric recap setting: kwarg > Config registry > built-in default.
    def self.recap_number_setting(kwarg_config, kwarg_key, config_key, default, numeric_type)
      value = kwarg_config[kwarg_key] || kwarg_config[kwarg_key.to_s]
      value = Samagotchi::Config.get(config_key) if value.nil? || value.to_s.strip.empty?
      value = default if value.nil? || value.to_s.strip.empty?
      numeric_type == :float ? value.to_f : value.to_i
    rescue StandardError
      numeric_type == :float ? default.to_f : default.to_i
    end
    private_class_method :recap_number_setting

    def self.string_config(config, key)
      value = config[key]
      value.to_s.strip.empty? ? nil : value.to_s
    end
    private_class_method :string_config
  end
end
