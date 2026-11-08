# frozen_string_literal: true

require_relative "token_usage"

module Samagotchi
  # A request's re-prefilled tokens, for both loops: of the prompt the last
  # request on the same model through the same client (the host) sent, what
  # the server didn't reuse from its cache this time (that prompt less the
  # cached count), so an LLM context edit's cache break shows, and so does
  # anything else that rewrote the prompt's middle or lost the cache.
  #
  # One per Engine, given to its KernelLoop and its ChatLoop, so the
  # baseline is the last request's whichever loop sent it: a switch to
  # another host and back starts over on the way back. A bare loop (a spec,
  # a bench) builds its own. Read and written on the turn's thread only
  # (each loop's completed generation; the turn-end warm-up's #reset!).
  class ReprefillMeter
    # The last counted request: its model, its client, its prompt tokens.
    Baseline = Data.define(:model, :client, :prompt)

    # The tokens the server prefilled again for this request (+prompt+ and
    # +cached+, its counts), and this request becomes the baseline. nil
    # under TokenUsage::REPREFILL_MIN_TOKENS (a cache block's rounding), for
    # a server that reports no cached count (or 0: a cold cache isn't told
    # from no cache), the first request, a model switch (another bare model,
    # or the same one on another host's +client+: SessionMetrics counts that
    # prefill as the switch's), and the first request after #reset!.
    # @return [Integer, nil]
    def tokens(model, client:, prompt:, cached:)
      previous = @baseline
      @baseline = Baseline.new(model: model, client: client, prompt: prompt.to_i) if prompt.to_i.positive?
      return nil unless previous && previous.model == model && previous.client.equal?(client) && cached.to_i.positive?

      tokens = previous.prompt - cached.to_i
      tokens >= TokenUsage::REPREFILL_MIN_TOKENS ? tokens : nil
    end

    # A turn-end warm-up prefilled the next prompt off the clock, so the
    # next request's cache counts are against it, not the last request:
    # start over (KernelLoop#warmed_up!).
    def reset!
      @baseline = nil
    end
  end
end
