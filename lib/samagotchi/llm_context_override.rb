# frozen_string_literal: true

require_relative "llm_context_strategy"

module Samagotchi
  # A session's own llm_context values (Session#llm_context), which come
  # before the model's, the host's and the global ones
  # (LLMContextStrategy.resolve): the layers ([] is none, set on purpose),
  # the apply rule and the budget in tokens (0 is off, set on purpose).
  # nil in a field is unset: that value follows the model, the host, then
  # llm_context.*, as with no override at all.
  #
  # Set by chi --llm-context, --llm-context-apply and --llm-context-budget
  # at start (or --resume), /llm-context in the session and the web's info
  # bar (which sends /llm-context). Saved in the session file, so a
  # --resume and a respawned worker keep it; a plugin's fork copies it,
  # a delegate child starts without one.
  LLMContextOverride = Data.define(:strategy, :apply, :budget_tokens) do
    def initialize(strategy: nil, apply: nil, budget_tokens: nil) = super

    def empty? = strategy.nil? && apply.nil? && budget_tokens.nil?

    # What the session file keeps: the set fields, nil when none is.
    # @return [Hash, nil]
    def to_file
      return nil if empty?

      { "strategy" => strategy&.map(&:to_s), "apply" => apply&.to_s, "budget_tokens" => budget_tokens }.compact
    end

    # LLMContextStrategy.resolve's session arguments.
    def resolve_args = { session: strategy, session_apply: apply, session_budget: budget_tokens }

    # How a field reads: "stale, forget", "none", "turn_end", "64000",
    # "off"; nil when unset.
    def self.word(field, value)
      return nil if value.nil?

      case field
      when :strategy then value.empty? ? "none" : value.join(", ")
      when :budget_tokens then value.positive? ? value.to_s : "off"
      else value.to_s
      end
    end
  end

  class LLMContextOverride
    FIELDS = %i[strategy apply budget_tokens].freeze
    # A field's word for "unset: follow the model" (/llm-context strategy default).
    DEFAULT_WORD = "default"
    OFF_WORDS = %w[off 0].freeze
    # The start flags (chi, chi send --new), by field.
    FLAGS = { strategy: "--llm-context", apply: "--llm-context-apply", budget_tokens: "--llm-context-budget" }.freeze
    # The session command, and its words by field.
    COMMAND = "/llm-context"
    COMMAND_WORDS = { strategy: "strategy", apply: "apply", budget_tokens: "budget" }.freeze

    # The /llm-context line that sets +words+ (field => value as typed,
    # checked by .update first): what a flag on an existing session runs.
    # @return [String]
    def self.command_line(words)
      parts = words.map do |field, word|
        word = word.to_s.strip
        word = parse_strategy(word).then { |layers| layers.empty? ? "none" : layers.join(",") } if field == :strategy && !word.casecmp?(DEFAULT_WORD)
        "#{COMMAND_WORDS.fetch(field)} #{word}"
      end
      [COMMAND, *parts].join(" ")
    end

    # A session file's "llm_context" (or an override already): nil when
    # absent or empty. A field that doesn't read (an unknown layer, an
    # out-of-range budget: a newer chi's, or a hand edit) is left unset,
    # without a warning: that value follows the model (.unread keeps it).
    # @return [LLMContextOverride, nil]
    def self.from_file(data)
      return data.empty? ? nil : data if data.is_a?(self)
      return nil unless data.is_a?(Hash)

      data = data.transform_keys(&:to_s)
      override = new(strategy: file_value { file_strategy(data["strategy"]) },
                     apply: file_value { parse_apply(data["apply"].to_s) unless data["apply"].nil? },
                     budget_tokens: file_value { file_budget(data["budget_tokens"]) })
      override.empty? ? nil : override
    end

    # The fields of a session file's "llm_context" that .from_file couldn't
    # read, as written (String keys): saved back as they were.
    # @return [Hash]
    def self.unread(data)
      return {} unless data.is_a?(Hash)

      data = data.transform_keys(&:to_s)
      read = from_file(data)
      FIELDS.each_with_object({}) do |field, unread|
        key = field.to_s
        unread[key] = data[key] if !data[key].nil? && read&.public_send(field).nil?
      end
    end

    def self.file_value
      yield
    rescue ArgumentError
      nil
    end

    def self.file_strategy(raw)
      return nil unless raw.is_a?(Array) || raw.is_a?(String)
      return [] if raw == []

      parse_strategy(Array(raw).join(","))
    end

    def self.file_budget(raw)
      raw.is_a?(Integer) ? check_budget(raw) : nil
    end

    # +current+ with +words+ (field => what the user typed) applied: each
    # word is a value, or "default" (unset). The flags and /llm-context
    # both go through here.
    # @param current [LLMContextOverride, nil]
    # @param words [Hash{Symbol => String}]
    # @return [LLMContextOverride]
    # @raise [ArgumentError] a word that isn't a value, saying which
    def self.update(current, words)
      fields = words.to_h do |field, word|
        raise ArgumentError, "unknown llm_context field #{field}" unless FIELDS.include?(field)

        text = word.to_s.strip
        [field, text.casecmp?(DEFAULT_WORD) ? nil : send(:"parse_#{field}", text)]
      end
      (current || new).with(**fields)
    end

    # "stale,forget", "stale forget", "stale|forget" or "none".
    # @return [Array<Symbol>] [] for none
    def self.parse_strategy(text)
      names = text.downcase.split(/[\s,|]+/).reject(&:empty?)
      raise ArgumentError, "a strategy is none or a list of #{LLMContextStrategy::LAYERS.join(", ")}" if names.empty?
      return [] if names == [LLMContextStrategy::NONE.to_s]

      unknown = names - LLMContextStrategy::LAYERS.map(&:to_s)
      unless unknown.empty?
        raise ArgumentError, "unknown llm_context strategy #{unknown.join(", ")} (none, or a list of " \
                             "#{LLMContextStrategy::LAYERS.join(", ")})"
      end
      LLMContextStrategy::LAYERS.select { |layer| names.include?(layer.to_s) }
    end

    # payoff, next_request or turn_end.
    # @return [Symbol]
    def self.parse_apply(text)
      rule = LLMContextStrategy::APPLIES.find { |name| name.to_s.casecmp?(text) }
      rule || raise(ArgumentError, "unknown llm_context apply #{text} (#{LLMContextStrategy::APPLIES.join(", ")})")
    end

    # The smallest and largest budget a session may set.
    MIN_BUDGET = 4_000
    MAX_BUDGET = 10_000_000

    # "64000", "64k" or "off" (0).
    # @return [Integer] 0 for off
    def self.parse_budget_tokens(text)
      return 0 if OFF_WORDS.include?(text.downcase)

      match = /\A(\d[\d_]*)(k)?\z/i.match(text)
      raise ArgumentError, "a budget is a number of tokens (64000 or 64k) or off" unless match

      check_budget(match[1].delete("_").to_i * (match[2] ? 1000 : 1))
    end

    # +tokens+, when 0 (off) or between MIN_BUDGET and MAX_BUDGET.
    def self.check_budget(tokens)
      return tokens if tokens.zero? || tokens.between?(MIN_BUDGET, MAX_BUDGET)

      raise ArgumentError, "a budget of #{tokens} tokens is out of range: #{MIN_BUDGET} (4k) to #{MAX_BUDGET} (10000k), or off"
    end

    private_class_method :file_value, :file_strategy, :file_budget
  end
end
