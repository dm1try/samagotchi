# frozen_string_literal: true

module Samagotchi
  # Which LLM context strategy a turn runs under (LLMContextView): none,
  # the default, or a list of layers (stale, forget). Set by
  # llm_context.strategy, and per model or host by the flat key
  # llm_context_strategy (models.<key>, hosts.<name>), each a layer name,
  # "|"-separated names or a YAML list.
  #
  # Resolution, first set wins: the session's own (a later per-session
  # override; nothing sets it yet), models.<key> (by the model's lookup
  # names, as window_tokens), hosts.<name>, then llm_context.strategy.
  # An unknown layer warns and is none; so is a strategy with a layer not
  # built yet (forget, P4): only none and stale are active.
  module LLMContextStrategy
    SETTING = "llm_context.strategy"
    KEY = "llm_context_strategy"
    NONE = :none
    LAYERS = %i[stale forget].freeze
    # The layers a turn can run under so far.
    BUILT = %i[stale].freeze

    # A turn's strategy: the layers as configured, the strategy the view
    # gets (NONE, or the layers), and where it was set (:session,
    # :model_setting, :host_setting, :config).
    Resolved = Data.define(:layers, :strategy, :source)

    module_function

    # +raw+ as written (a String, "|"-separated, or a YAML list) as layers;
    # [] for none, nil for unset. An unknown name warns, naming +where+,
    # and is none.
    # @return [Array<Symbol>, nil]
    def parse(raw, where)
      return nil if raw.nil?

      names = (raw.is_a?(Array) ? raw : raw.to_s.split("|")).map { |name| name.to_s.strip.downcase }.reject(&:empty?)
      return [] if names.empty? || names == [NONE.to_s]

      unknown = names - LAYERS.map(&:to_s)
      unless unknown.empty?
        warn_once "Warning: #{where}: unknown llm_context strategy #{unknown.join(", ")} (none, or a list of " \
                  "#{LAYERS.join(", ")}); using none"
        return []
      end
      names.uniq.map(&:to_sym)
    end

    # The strategy for +target+'s turn.
    # @param target [HostRegistry::ModelTarget, nil]
    # @param names [Array<String>] HostRegistry#lookup_names
    # @param models [Hash, nil] ConfigFile.model_settings (specs)
    # @param session [Array<Symbol>, nil] the session's own layers (none yet)
    # @return [Resolved]
    def resolve(target, names:, models: nil, session: nil)
      return resolved(session, :session, "the session") if session

      models ||= ConfigFile.model_settings
      key, layers = ConfigFile.model_setting(names, :llm_context_strategy, models: models)
      return resolved(layers, :model_setting, "models: #{key}") if layers

      layers = target&.entry&.llm_context_strategy
      return resolved(layers, :host_setting, "hosts entry '#{target.entry.name}'") if layers

      resolved(parse(Config.get(SETTING), SETTING) || [], :config, SETTING)
    end

    def resolved(layers, source, where)
      unbuilt = layers - BUILT
      unless unbuilt.empty?
        warn_once "Warning: #{where}: llm_context strategy #{unbuilt.join(", ")} is not built yet; using none"
      end
      Resolved.new(layers: layers, strategy: layers.empty? || !unbuilt.empty? ? NONE : layers, source: source)
    end

    def warn_once(message) = ConfigFile.warn_once(message)

    private_class_method :resolved, :warn_once
  end
end
