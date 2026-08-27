# frozen_string_literal: true

module Samagotchi
  # Normalizes raw model-server stream payloads into a uniform context-usage
  # snapshot. Shared by the kernel loop (to inform the model of real token
  # usage) and the terminal UI (to render the status line) so both agree on
  # token accounting instead of duplicating the parsing logic.
  module ContextUsage
    DEFAULT_CONTEXT_WINDOW_TOKENS = 256_000
    CONTEXT_WINDOW_TOKENS_ENV = "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"

    module_function

    def first_positive_integer(*values)
      values.each do |value|
        integer = Integer(value)
        return integer if integer.positive?
      rescue ArgumentError, TypeError
        next
      end

      nil
    end

    def normalize(payload)
      payload_hash = payload.is_a?(Hash) ? payload : {}
      usage = payload_hash["usage"] || payload_hash[:usage]
      usage = {} unless usage.is_a?(Hash)

      prompt_tokens = first_positive_integer(
        usage["prompt_tokens"], usage[:prompt_tokens],
        payload_hash["prompt_tokens"], payload_hash[:prompt_tokens],
        payload_hash["prompt_n"], payload_hash[:prompt_n],
        payload_hash["tokens_evaluated"], payload_hash[:tokens_evaluated],
        payload_hash.dig("timings", "prompt_n"), payload_hash.dig(:timings, :prompt_n)
      )

      completion_tokens = first_positive_integer(
        usage["completion_tokens"], usage[:completion_tokens],
        payload_hash["completion_tokens"], payload_hash[:completion_tokens],
        payload_hash["predicted_n"], payload_hash[:predicted_n],
        payload_hash["tokens_predicted"], payload_hash[:tokens_predicted],
        payload_hash.dig("timings", "predicted_n"), payload_hash.dig(:timings, :predicted_n)
      )

      total_tokens = first_positive_integer(
        usage["total_tokens"], usage[:total_tokens],
        payload_hash["total_tokens"], payload_hash[:total_tokens],
        payload_hash["n_past"], payload_hash[:n_past]
      )
      total_tokens ||= prompt_tokens.to_i + completion_tokens.to_i if prompt_tokens || completion_tokens

      context_window_tokens = first_positive_integer(
        payload_hash["n_ctx"], payload_hash[:n_ctx],
        payload_hash["context_window"], payload_hash[:context_window],
        ENV[CONTEXT_WINDOW_TOKENS_ENV],
        DEFAULT_CONTEXT_WINDOW_TOKENS
      )

      context_used_tokens = first_positive_integer(
        payload_hash["n_past"], payload_hash[:n_past],
        total_tokens
      )

      ctx_pct = if context_window_tokens && context_used_tokens
                  (context_used_tokens.to_f / context_window_tokens) * 100.0
                end

      return nil unless prompt_tokens || completion_tokens || total_tokens || ctx_pct

      {
        prompt_tokens: prompt_tokens,
        completion_tokens: completion_tokens,
        total_tokens: total_tokens,
        context_window_tokens: context_window_tokens,
        ctx_pct: ctx_pct
      }
    end
  end
end
