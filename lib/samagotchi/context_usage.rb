# frozen_string_literal: true

require_relative "token_usage"

module Samagotchi
  # Normalizes raw model-server stream payloads into a uniform context-usage
  # snapshot. Shared by the kernel loop (to inform the model of real token
  # usage) and the terminal UI (to render the status line) so both agree on
  # token accounting instead of duplicating the parsing logic.
  module ContextUsage
    module_function

    # Numbers read like TokenUsage's: integers, floats and numeric strings,
    # decimal ("010" is 10).
    def first_positive_integer(*values)
      TokenUsage.first_positive(*values)
    end

    # `window_tokens` is the caller's resolved context window; a window the
    # payload reports itself (n_ctx / context_window) wins over it. Without
    # either, context_window_tokens and ctx_pct stay nil: the parser does not
    # invent a default.
    def normalize(payload, window_tokens: nil)
      payload_hash = payload.is_a?(Hash) ? payload : {}
      usage = payload_hash["usage"] || payload_hash[:usage]
      usage = {} unless usage.is_a?(Hash)

      # The token counts come from the same parser SessionMetrics uses.
      counts = TokenUsage.from_payload(payload_hash) || {}
      prompt_tokens = counts[:prompt_tokens]
      completion_tokens = counts[:completion_tokens]

      total_tokens = first_positive_integer(
        usage["total_tokens"], usage[:total_tokens],
        payload_hash["total_tokens"], payload_hash[:total_tokens],
        payload_hash["n_past"], payload_hash[:n_past]
      )
      total_tokens ||= prompt_tokens.to_i + completion_tokens.to_i if prompt_tokens || completion_tokens

      context_window_tokens = first_positive_integer(
        payload_hash["n_ctx"], payload_hash[:n_ctx],
        payload_hash["context_window"], payload_hash[:context_window],
        window_tokens
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
