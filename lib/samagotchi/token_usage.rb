# frozen_string_literal: true

module Samagotchi
  # TokenUsage extracts real server-reported token counts from a model API
  # stream payload, transport-agnostically.
  #
  # llama.cpp's /completion stream emits per-chunk `timings.prompt_n` /
  # `timings.predicted_n` (cumulative) and a final top-level
  # `tokens_evaluated` / `tokens_predicted`. mlx_lm.server (OpenAI-compatible)
  # emits a `usage` object with `prompt_tokens` / `completion_tokens`.
  #
  # Returns nil when no server token data is present, so a caller can fall back
  # to a chars/4 heuristic. The reported values are cumulative per request, so
  # callers should take the running MAX across chunks (see SessionMetrics).
  class TokenUsage
    CHARS_PER_TOKEN = 4.0

    class << self
      # @param payload [Hash, nil] the raw streamed chunk payload
      # @return [Hash, nil] { prompt_tokens:, completion_tokens:, source: :server }
      def from_payload(payload)
        payload_hash = payload.is_a?(Hash) ? payload : {}
        usage = payload_hash["usage"] || payload_hash[:usage]
        usage = {} unless usage.is_a?(Hash)

        prompt_tokens = first_positive(
          usage["prompt_tokens"],
          usage[:prompt_tokens],
          payload_hash["prompt_tokens"],
          payload_hash[:prompt_tokens],
          payload_hash["prompt_n"],
          payload_hash[:prompt_n],
          payload_hash["tokens_evaluated"],
          payload_hash[:tokens_evaluated],
          payload_hash.dig("timings", "prompt_n"),
          payload_hash.dig(:timings, :prompt_n)
        )

        completion_tokens = first_positive(
          usage["completion_tokens"],
          usage[:completion_tokens],
          payload_hash["completion_tokens"],
          payload_hash[:completion_tokens],
          payload_hash["predicted_n"],
          payload_hash[:predicted_n],
          payload_hash["tokens_predicted"],
          payload_hash[:tokens_predicted],
          payload_hash.dig("timings", "predicted_n"),
          payload_hash.dig(:timings, :predicted_n)
        )

        return nil unless prompt_tokens || completion_tokens

        {
          prompt_tokens: prompt_tokens,
          completion_tokens: completion_tokens,
          source: :server
        }
      end

      # Estimate token count from raw text length using the chars/4 heuristic.
      # @param text [String]
      # @return [Integer]
      def estimate(text)
        return 0 unless text.is_a?(String)

        (text.length / CHARS_PER_TOKEN).ceil
      end

      private

      def first_positive(*values)
        values.each do |value|
          integer = Integer(value)
          return integer if integer.positive?
        rescue ArgumentError, TypeError
          next
        end

        nil
      end
    end
  end
end
