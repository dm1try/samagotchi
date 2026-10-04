# frozen_string_literal: true

module Samagotchi
  # TokenUsage is the server-reported token accounting of one model API stream
  # payload, read transport-agnostically.
  #
  # llama.cpp's /completion stream emits per-chunk `timings.prompt_n` /
  # `timings.predicted_n` (cumulative) and a final top-level
  # `tokens_evaluated` / `tokens_predicted`. OpenAI-compatible servers emit a
  # `usage` object with `prompt_tokens` / `completion_tokens`.
  #
  # The last chunk can say more: llama.cpp adds a `timings` block with exact
  # speeds and `cache_n` (its native `tokens_cached` counts the new tokens too,
  # so it is not read); OpenRouter adds `usage.cost` (USD) and the
  # `prompt_tokens_details.cached_tokens` / `cache_write_tokens` /
  # `completion_tokens_details.reasoning_tokens` breakdowns (cache writes:
  # Anthropic models, prompt caching's first request). Those fields are nil when a payload doesn't carry them.
  #
  # from_payload returns nil when no server token counts are present, so a
  # caller can fall back to a chars/4 heuristic. The reported values are
  # cumulative per request, so callers should take the running MAX across
  # chunks (see SessionMetrics).
  class TokenUsage < Data.define(:prompt_tokens, :completion_tokens, :cached_tokens, :cache_write_tokens,
                                 :reasoning_tokens, :cost, :predicted_per_second, :prompt_per_second, :predicted_ms, :source)
    CHARS_PER_TOKEN = 4.0

    class << self
      # @param payload [Hash, nil] the raw streamed chunk payload
      # @return [TokenUsage, nil]
      def from_payload(payload)
        payload_hash = payload.is_a?(Hash) ? payload : {}
        usage = hash_at(payload_hash, :usage)
        timings = hash_at(payload_hash, :timings)

        prompt_tokens = first_positive(
          *both(usage, :prompt_tokens), *both(payload_hash, :prompt_tokens), *both(payload_hash, :prompt_n),
          *both(payload_hash, :tokens_evaluated), *both(timings, :prompt_n)
        )
        completion_tokens = first_positive(
          *both(usage, :completion_tokens), *both(payload_hash, :completion_tokens),
          *both(payload_hash, :predicted_n), *both(payload_hash, :tokens_predicted), *both(timings, :predicted_n)
        )
        return nil unless prompt_tokens || completion_tokens

        details = hash_at(usage, :prompt_tokens_details)
        new(
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          cached_tokens: first_positive(*both(details, :cached_tokens), *both(timings, :cache_n)),
          cache_write_tokens: first_positive(*both(details, :cache_write_tokens)),
          reasoning_tokens: first_positive(*both(hash_at(usage, :completion_tokens_details), :reasoning_tokens)),
          cost: number(*both(usage, :cost)),
          predicted_per_second: positive_number(*both(timings, :predicted_per_second)),
          prompt_per_second: positive_number(*both(timings, :prompt_per_second)),
          predicted_ms: positive_number(*both(timings, :predicted_ms)),
          source: :server
        )
      end

      # A request's prompt-cache counts as a :generation_completed event
      # carries them (the log line too): the prompt, the part of it the
      # server reused from its cache, and the part it wrote to it (nil when
      # none: only some remote servers report writes).
      # @return [Hash] {prompt_tokens:, cached_tokens:, cache_write_tokens:}
      def cache_fields(prompt:, cached:, cache_write:)
        { prompt_tokens: prompt.to_i, cached_tokens: cached.to_i,
          cache_write_tokens: cache_write.to_i.positive? ? cache_write.to_i : nil }
      end

      # Estimate token count from raw text length using the chars/4 heuristic.
      # @param text [String]
      # @return [Integer]
      def estimate(text)
        return 0 unless text.is_a?(String)

        (text.length / CHARS_PER_TOKEN).ceil
      end

      # Coerce each candidate to an integer (ContextUsage reads its own fields
      # with this too), accepting integers, numeric strings,
      # and floats (e.g. a JSON backend emitting 50.0). Truncates via to_i so a
      # float never raises RangeError; non-numeric values are skipped.
      def first_positive(*values)
        values.each do |value|
          n = float(value)&.to_i
          return n if n&.positive?
        end

        nil
      end

      private

      def hash_at(hash, key)
        value = hash[key.to_s] || hash[key]
        value.is_a?(Hash) ? value : {}
      end

      def both(hash, key) = [hash[key.to_s], hash[key]]

      def positive_number(*values) = values.filter_map { |value| float(value) }.find(&:positive?)

      # A cost of 0 is a real answer (a free model), so zero counts here.
      def number(*values) = values.filter_map { |value| float(value) }.find { |n| n >= 0 }

      def float(value)
        return nil if value.nil?

        n = Float(value)
        n.finite? ? n : nil
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
