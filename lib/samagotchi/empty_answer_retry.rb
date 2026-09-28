# frozen_string_literal: true

require_relative "config"
require_relative "turn_note"

module Samagotchi
  # Asking the model again, in the same turn, when a generation ends with no
  # visible text and no tool calls (thinking only, or nothing): a hidden
  # nudge (TurnNote.empty_retry), then another generation. Both loops use
  # it; the Engine's TurnNote.empty is what's left when the retries run out.
  module EmptyAnswerRetry
    MAX = 3
    # Greedy decoding on a near-identical prompt would likely loop again:
    # the retry runs at this temperature unless one is configured.
    TEMPERATURE = 0.6
    # A generation cut at the provider's output cap (finish_reason length)
    # is retried unless the context is this full.
    CONTEXT_FULL_RATIO = 0.9

    module_function

    # retry.empty_answer, 0..MAX.
    def limit
      Config.get("retry.empty_answer").to_i.clamp(0, MAX)
    rescue StandardError
      1
    end

    # The request options of a retry generation: the turn's sampling, with
    # TEMPERATURE when it sets none (a configured nil keeps "don't send").
    def sampling(base)
      base = base || {}
      base.key?(:temperature) ? base : base.merge(temperature: TEMPERATURE)
    end

    # The prompt filled the window (a length stop is then no loop to break).
    def context_full?(used_tokens, window_tokens)
      return false unless used_tokens.to_i.positive? && window_tokens.to_i.positive?

      used_tokens.to_f / window_tokens >= CONTEXT_FULL_RATIO
    end
  end
end
