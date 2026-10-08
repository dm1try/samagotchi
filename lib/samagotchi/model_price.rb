# frozen_string_literal: true

module Samagotchi
  # A model's price on a host (hosts.<name>.models.<id>.price), in USD per
  # 1M tokens: what a generation's cost is estimated from when the provider
  # reports none (SessionMetrics, cost_estimate). An unset cache rate is the
  # input rate: that overstates cached reads, and understates Anthropic
  # cache writes (billed 1.25x input for the 5 min cache, 2x for 1 h).
  ModelPrice = Data.define(:input, :cache_read, :cache_write, :output) do
    # @param raw [Hash, nil] the price as written
    # @param where [String] for the warning
    # @return [ModelPrice, nil] nil when unset or invalid (warned once)
    def self.parse(raw, where)
      return nil if raw.nil?

      values = raw.is_a?(Hash) ? raw.transform_keys(&:to_s).slice(*ModelPrice::KEYS) : nil
      valid = values && values.key?("input") && values.key?("output") &&
              # YAML's .inf and .nan are Floats too: JSON can't carry them
              # (hosts_json_for_env would drop every host) and NaN poisons the sums.
              values.values.all? { |v| v.is_a?(Numeric) && v.finite? && !v.negative? }
      unless valid
        warn_once "Warning: #{where}.price needs input and output, each a number >= 0 (USD per 1M tokens); ignored"
        return nil
      end
      new(input: values["input"], cache_read: values.fetch("cache_read", values["input"]),
          cache_write: values.fetch("cache_write", values["input"]), output: values["output"])
    end

    # config.rb requires model_price through host_model, so config is
    # required here only when a warning needs it.
    def self.warn_once(message)
      require_relative "config"
      ConfigFile.warn_once(message)
    end
    private_class_method :warn_once

    # USD for one generation, OpenAI usage semantics: +prompt_tokens+ holds
    # the cached reads and the cache writes (OpenRouter keeps that for
    # Anthropic models), and reasoning is inside +completion_tokens+.
    # llama.cpp's native timings.prompt_n leaves its cache_n out, so the
    # uncached part is clamped at 0: an undercount, harmless because priced
    # models are remote.
    def cost(prompt_tokens:, cached_tokens:, cache_write_tokens:, completion_tokens:)
      uncached = (prompt_tokens - cached_tokens - cache_write_tokens).clamp(0..)
      ((uncached * input) + (cached_tokens * cache_read) + (cache_write_tokens * cache_write) +
       (completion_tokens * output)) / 1e6
    end

    def to_config = to_h.transform_keys(&:to_s)
  end

  # The keys a price may hold (config validation checks them too).
  ModelPrice::KEYS = %w[input cache_read cache_write output].freeze
end
