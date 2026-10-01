# frozen_string_literal: true

require_relative "config"
require_relative "log"
require_relative "turn_note"

module Samagotchi
  # Asking the model again, in the same turn, when a generation ends with no
  # visible text and no tool calls (thinking only, or nothing): a hidden
  # nudge (TurnNote.empty_retry), then another generation. A generation a
  # plugin cut (stop_generation) spends the same budget with its own nudge.
  # Both loops keep one per turn; the Engine's TurnNote.empty is what's left
  # when the retries run out.
  class EmptyAnswerRetry
    MAX = 3
    # Greedy decoding on a near-identical prompt would likely loop again:
    # the retry runs at this temperature unless one is configured.
    TEMPERATURE = 0.6
    # A generation cut at the provider's output cap (finish_reason length)
    # is retried unless the context is this full.
    CONTEXT_FULL_RATIO = 0.9

    # retry.empty_answer, 0..MAX.
    def self.limit
      Config.get("retry.empty_answer").to_i.clamp(0, MAX)
    rescue StandardError
      1
    end

    # The request options of a retry generation: the turn's sampling, with
    # TEMPERATURE when it sets none (a configured nil keeps "don't send").
    def self.sampling(base)
      base = base || {}
      base.key?(:temperature) ? base : base.merge(temperature: TEMPERATURE)
    end

    # The prompt filled the window (a length stop is then no loop to break).
    def self.context_full?(used_tokens, window_tokens)
      return false unless used_tokens.to_i.positive? && window_tokens.to_i.positive?

      used_tokens.to_f / window_tokens >= CONTEXT_FULL_RATIO
    end

    attr_reader :limit

    def initialize(limit: self.class.limit)
      @limit = limit
      @attempts = 0
      @armed = false
    end

    # An attempt is left.
    def left? = @attempts < @limit

    # A nudge went out this turn.
    def used? = @attempts.positive?

    # An empty answer is asked again: an attempt is left, the turn wasn't
    # cancelled, and the answer wasn't cut short by a full context (a
    # length stop while thinking is retried: a thinking loop cut by the
    # output cap, not a full window).
    def retry_empty?(iteration:, cancelled:, finish_reason: nil, used_tokens: nil, window_tokens: nil)
      return false if !left? || cancelled

      if finish_reason.to_s == "length" && self.class.context_full?(used_tokens, window_tokens)
        Log.info(:turn, "empty_answer_not_retried", iteration: iteration, why: "context full")
        return false
      end
      true
    end

    # Spends an attempt: :empty_answer_retry (with +fields+) goes out, +note+
    # goes on the tail, and the next request runs at the retry sampling.
    # Returns true.
    def nudge!(conversation, note, emit:, iteration:, **fields)
      @attempts += 1
      @armed = true
      emit.call({ type: :empty_answer_retry, iteration: iteration, attempt: @attempts, of: @limit, **fields })
      conversation << note
      true
    end

    # Whether this request is the retry (once per nudge).
    def take_sampling!
      armed = @armed
      @armed = false
      armed
    end

    # This request's sampling: the retry's once after a nudge, else +base+.
    def request_sampling(base)
      take_sampling! ? self.class.sampling(base) : base
    end

    # The last spent nudge goes (a retry that failed too: the Engine's
    # TurnNote.empty says it all).
    def drop_nudge!(conversation)
      index = conversation.rindex { |entry| TurnNote.retry_nudge?(entry) }
      conversation.delete_at(index) if index
    end
  end
end
