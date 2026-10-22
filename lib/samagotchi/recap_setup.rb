# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "idle_recap"
require_relative "idle_target"
require_relative "recap_store"

module Samagotchi
  # Builds (or disables) an Engine's idle recap job from the `recap:` kwarg,
  # the session's own settings and the Config registry. The Engine builds
  # one at start, and again when it binds a session whose own recap values
  # differ (Engine#session=).
  module RecapSetup
    # Build (or disable) the idle recap job. On by default: with no recap
    # host or model configured it asks the session's current model on its
    # host, resolved at each attempt the way a turn does (a /model switch
    # counts). An explicit `recap: {host_ref:, model:}` or `{base_url:,
    # model:}` pins it; a model alone goes to its host, or where a bare
    # --model goes; an incomplete one warns and leaves recap off.
    #
    # Single precedence path: explicit `recap:` kwarg > Config registry
    # (session > CLI > ENV > file > default). An explicit disable
    # (`recap: false` as the kwarg or in the config file, `recap: {enabled:
    # false}`, or SAMAGOTCHI_RECAP_ENABLED=false) wins, but over a session's
    # own recap.enabled (chi --set recap.enabled=true) only as the kwarg.
    #
    # @param recap          [Hash, false, nil] the Engine's `recap:` kwarg
    # @param engine         [Engine] the recap job's engine
    # @param host_registry  [HostRegistry]
    # @param session_target [#call] → the session's current model as a recap target
    # @param session_id     [#call] → String, nil
    # @param state_dir      [#call] → String
    # @param session_config [#call] → the session's own core settings
    #   (SessionConfig::Settings#core), read once here
    # @return [IdleRecap, nil]
    def self.build(recap, engine:, host_registry:, session_target:, session_id:, state_dir:, session_config: -> { {} })
      return nil if recap == false

      session = session_config.call || {}
      # The session's own recap.enabled replaces both checks below.
      if session.key?("recap.enabled")
        return nil unless session["recap.enabled"]
      else
        # The REPL and a worker pass nothing: the config is read here alone
        # (a scalar `recap: false` is only seen this way).
        return nil if recap.nil? && ConfigFile.recap_config == false
        return nil if Samagotchi::Config.get("recap.enabled") == false
      end

      # An explicit kwarg (a spec, an embedder) over the registry.
      kwarg_config = recap.is_a?(Hash) ? recap : {}

      base_url = string_config(kwarg_config, :base_url) || registry_string("recap.base_url")
      host_ref = string_config(kwarg_config, :host_ref) || string_config(kwarg_config, :host) || registry_string("recap.host_ref")
      model = string_config(kwarg_config, :model) || registry_string("recap.model")

      settings = { model: model, host_ref: host_ref, base_url: base_url, host_registry: host_registry }
      target = if base_url.nil? && host_ref.nil? && model.nil?
                 -> { session_target.call }
               elsif !IdleTarget.host_named?(**settings)
                 # A model naming no host goes where a bare --model goes
                 # (HostRegistry#host_for_model: the default host unless
                 # another lists or declares it), resolved at each attempt.
                 -> { IdleTarget.resolve(**settings) }
               else
                 fixed = fixed_target(settings)
                 return nil unless fixed

                 -> { fixed }
               end

      IdleRecap.new(
        engine: engine,
        target: target,
        inactivity: recap_number_setting(kwarg_config, :inactivity, "recap.inactivity", IdleRecap::DEFAULT_INACTIVITY_SECONDS, :float),
        min_user_turns: recap_number_setting(kwarg_config, :min_user_turns, "recap.min_user_turns", IdleRecap::DEFAULT_MIN_USER_TURNS, :int),
        timeout: recap_number_setting(kwarg_config, :timeout, "recap.timeout", IdleRecap::DEFAULT_TIMEOUT_SECONDS, :float),
        sentences: recap_sentences(string_config(kwarg_config, :sentences) || registry_string("recap.sentences", session: session)),
        store: RecapStore.new(session_id_lookup: -> { session_id.call }, state_dir_lookup: -> { state_dir.call }),
        session_id: -> { session_id.call },
        on_usage: ->(usage) { engine.note_side_usage(usage) }
      )
    end

    # The recap's pinned host and model (IdleTarget.resolve), or nil after
    # a warning when they can't be resolved (recap stays off).
    # @return [IdleTarget, nil]
    def self.fixed_target(settings)
      IdleTarget.resolve(**settings)
    rescue IdleTarget::Unresolved => e
      case e.reason
      when :host_ref_unknown
        Log.warn(:recap, "host_ref_unknown", echo: "Warning: recap host_ref '#{e.host_ref}' not found in hosts:; recap disabled.",
                                             host_ref: e.host_ref)
      when :model_host_mismatch
        Log.warn(:recap, "model_host_mismatch",
                 echo: "Warning: recap model '#{e.model}' names host '#{e.named}', not recap.host_ref '#{e.host_ref}'; recap disabled.",
                 model: e.model, host_ref: e.host_ref)
      else
        Log.warn(:recap, "recap_unconfigured",
                 echo: "Warning: SAMAGOTCHI session recap is enabled but base_url/model are missing; recap disabled. " \
                       "Set recap: {host_ref:, model:} or SAMAGOTCHI_RECAP_BASE_URL and SAMAGOTCHI_RECAP_MODEL (or pass recap: {base_url:, model:}), " \
                       "or leave them all out to recap with the session's own model.")
      end
      nil
    end
    private_class_method :fixed_target

    # recap.sentences as [min, max]; an invalid value warns and falls back to
    # the default range (the recap stays on).
    def self.recap_sentences(value)
      range = IdleRecap::RecapPrompt.sentences_range(value)
      return range if range

      default = IdleRecap::RecapPrompt::DEFAULT_SENTENCES
      Log.warn(:recap, "sentences_invalid", echo: "Warning: invalid value for recap.sentences: #{value.to_s.inspect} — using #{default.join("-")}",
                                            value: value.to_s)
      default
    end
    private_class_method :recap_sentences

    # Read a scalar recap setting via the Config registry (session > CLI >
    # ENV > file > default).
    def self.registry_string(key, session: nil)
      value = Samagotchi::Config.get(key, session: session)
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
