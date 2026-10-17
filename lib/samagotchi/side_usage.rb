# frozen_string_literal: true

module Samagotchi
  # One side request's usage (an idle recap, a plugin's ctx.ask_model such
  # as /btw): what IdleClient reports to its on_usage callback and
  # SessionMetrics#add_side folds into the session's side line, apart from
  # its turns' totals.
  # @!attribute kind [String] "recap", or the asking bundle's name ("btw")
  # @!attribute model [String] the target's model, for the log
  # @!attribute prompt_tokens [Integer] 0 when not reported (and the rest)
  # @!attribute completion_tokens [Integer]
  # @!attribute cached_tokens [Integer]
  # @!attribute cache_write_tokens [Integer]
  # @!attribute reasoning_tokens [Integer]
  # @!attribute cost [Float, nil] the provider's reported cost (OpenRouter's
  #   usage.cost), nil when not reported
  # @!attribute price [ModelPrice, nil] the target host's price for the
  #   model (IdleTarget#price), what the cost is estimated from
  SideUsage = Data.define(:kind, :model, :prompt_tokens, :completion_tokens, :cached_tokens, :cache_write_tokens,
                          :reasoning_tokens, :cost, :price) do
    def initialize(kind:, model: nil, prompt_tokens: 0, completion_tokens: 0, cached_tokens: 0, cache_write_tokens: 0,
                   reasoning_tokens: 0, cost: nil, price: nil)
      super
    end

    # A response's usage (LLM::Usage; Usage.none's zeros when the server
    # reported no counts: still one request) as a side request's.
    # @param usage [LLM::Usage, nil]
    # @return [SideUsage]
    def self.from_usage(usage, kind:, model:, price:)
      count = ->(name) { usage.respond_to?(name) ? usage.public_send(name).to_i : 0 }
      new(kind: kind.to_s, model: model, prompt_tokens: count.call(:prompt_tokens),
          completion_tokens: count.call(:completion_tokens), cached_tokens: count.call(:cached_tokens),
          cache_write_tokens: count.call(:cache_write_tokens), reasoning_tokens: count.call(:reasoning_tokens),
          cost: usage.respond_to?(:cost) ? usage.cost : nil, price: price)
    end
  end
end
