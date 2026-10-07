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
  # An unknown layer warns and is none (every layer is built: stale, and
  # forget, experimental, with its tool forget_outputs).
  #
  # When a layer's edits reach the prompt (LLMContextApply) is set by
  # llm_context.apply, and per model or host by the flat key
  # llm_context_apply: payoff (the default), next_request or turn_end,
  # resolved as the strategy is (the session's own, the model's, the
  # host's, then llm_context.apply), each layer on its own: a model may
  # set the strategy and its host the apply rule. An unknown value warns
  # and is payoff. llm_context.protect_steps (3) and llm_context.stale_edits
  # (false: edit-driven stale stubs are opt-in, experimental) are global only.
  #
  # A soft context budget, llm_context.budget_tokens, and per model or host
  # the flat key llm_context_budget_tokens (a positive number of tokens),
  # resolved as the apply rule is, each on its own: off (nil) by default.
  # When set, ContextStatus counts its bands against it instead of the
  # window (the smaller of the two), so the forget layer's offers come
  # under it.
  module LLMContextStrategy
    SETTING = "llm_context.strategy"
    KEY = "llm_context_strategy"
    NONE = :none
    LAYERS = %i[stale forget].freeze
    # The layers a turn can run under so far.
    BUILT = %i[stale forget].freeze
    # The sentence forget_outputs' description carries (global only):
    # the plan's D7 line, adapted from CLM's steering example.
    POLICY_SETTING = "llm_context.policy"
    DEFAULT_POLICY = "Tidy at subtask boundaries: once a subtask is done, forget its tool outputs and note what it " \
                     "established; keep anything you'll still edit against."

    APPLY_SETTING = "llm_context.apply"
    APPLY_KEY = "llm_context_apply"
    APPLIES = %i[payoff next_request turn_end].freeze
    DEFAULT_APPLY = :payoff
    PROTECT_SETTING = "llm_context.protect_steps"
    DEFAULT_PROTECT_STEPS = 3
    STALE_EDITS_SETTING = "llm_context.stale_edits"
    BUDGET_SETTING = "llm_context.budget_tokens"
    BUDGET_KEY = "llm_context_budget_tokens"

    # A turn's strategy: the layers as configured, the strategy the view
    # gets (NONE, or the layers), and where it was set (:session,
    # :model_setting, :host_setting, :config); the apply rule
    # (LLMContextApply), the steps whose edited files' reads are kept
    # (protect_steps), whether an edit or write makes a read stale
    # (stale_edits; off: later reads only), and the context budget in
    # tokens (budget_tokens; nil: off).
    Resolved = Data.define(:layers, :strategy, :source, :apply, :protect_steps, :stale_edits, :budget_tokens) do
      def initialize(apply: DEFAULT_APPLY, protect_steps: DEFAULT_PROTECT_STEPS, stale_edits: false, budget_tokens: nil,
                     **fields) = super

      def forget? = active_layers.include?(:forget)

      # The layers the turn runs under: none of them under none (an
      # unbuilt or unknown layer's strategy too).
      def active_layers = strategy == NONE ? [] : Array(strategy)
    end

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

    # +raw+ as written, an apply rule; nil for unset. An unknown one warns,
    # naming +where+, and is payoff.
    # @return [Symbol, nil]
    def parse_apply(raw, where)
      return nil if raw.nil? || raw.to_s.strip.empty?

      rule = raw.to_s.strip.downcase.to_sym
      return rule if APPLIES.include?(rule)

      warn_once "Warning: #{where}: unknown llm_context apply #{raw} (#{APPLIES.join(", ")}); using #{DEFAULT_APPLY}"
      DEFAULT_APPLY
    end

    # +raw+ as written, a context budget in tokens; nil for unset or 0
    # (off). Anything but a number of tokens warns, naming +where+, and is
    # unset.
    # @return [Integer, nil]
    def parse_budget(raw, where)
      return nil if raw.nil? || raw.to_s.strip.empty?

      tokens = Integer(raw.to_s.strip, exception: false)
      return nil if tokens&.zero?
      return tokens if tokens&.positive?

      warn_once "Warning: #{where}: llm_context budget_tokens must be a positive number of tokens; ignored"
      nil
    end

    # The strategy for +target+'s turn.
    # @param target [HostRegistry::ModelTarget, nil]
    # @param names [Array<String>] HostRegistry#lookup_names
    # @param models [Hash, nil] ConfigFile.model_settings (specs)
    # @param session [Array<Symbol>, nil] the session's own layers (none yet)
    # @param session_apply [Symbol, nil] the session's own apply rule (none yet)
    # @param session_budget [Integer, nil] the session's own budget (none yet)
    # @return [Resolved]
    def resolve(target, names:, models: nil, session: nil, session_apply: nil, session_budget: nil)
      models ||= ConfigFile.model_settings
      layers, source, where = layers_for(target, names, models, session)
      resolved(layers, source, where).with(apply: apply_for(target, names, models, session_apply),
                                           protect_steps: protect_steps, stale_edits: Config.get(STALE_EDITS_SETTING) == true,
                                           budget_tokens: budget_for(target, names, models, session_budget))
    end

    def budget_for(target, names, models, session_budget)
      session_budget || ConfigFile.model_setting(names, :llm_context_budget_tokens, models: models)&.last ||
        target&.entry&.llm_context_budget_tokens || parse_budget(Config.get(BUDGET_SETTING), BUDGET_SETTING)
    end

    def layers_for(target, names, models, session)
      return [session, :session, "the session"] if session

      key, layers = ConfigFile.model_setting(names, :llm_context_strategy, models: models)
      return [layers, :model_setting, "models: #{key}"] if layers

      layers = target&.entry&.llm_context_strategy
      return [layers, :host_setting, "hosts entry '#{target.entry.name}'"] if layers

      [parse(Config.get(SETTING), SETTING) || [], :config, SETTING]
    end

    def apply_for(target, names, models, session_apply)
      session_apply || ConfigFile.model_setting(names, :llm_context_apply, models: models)&.last ||
        target&.entry&.llm_context_apply || parse_apply(Config.get(APPLY_SETTING), APPLY_SETTING) || DEFAULT_APPLY
    end

    # llm_context.protect_steps: 0 or more (a negative one is the default).
    def protect_steps
      steps = Config.get(PROTECT_SETTING)
      steps.is_a?(Integer) && !steps.negative? ? steps : DEFAULT_PROTECT_STEPS
    end

    def resolved(layers, source, where)
      unbuilt = layers - BUILT
      unless unbuilt.empty?
        warn_once "Warning: #{where}: llm_context strategy #{unbuilt.join(", ")} is not built yet; using none"
      end
      Resolved.new(layers: layers, strategy: layers.empty? || !unbuilt.empty? ? NONE : layers, source: source)
    end

    def warn_once(message) = ConfigFile.warn_once(message)

    private_class_method :resolved, :warn_once, :layers_for, :apply_for, :budget_for
  end
end
