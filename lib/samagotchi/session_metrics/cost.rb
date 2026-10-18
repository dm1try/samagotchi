# frozen_string_literal: true

module Samagotchi
  class SessionMetrics
    # The session's spend so far (SessionMetrics#cost, what a bundle's
    # ctx.cost reads), in USD: +reported+ by providers (usage.cost) and
    # +estimated+ from configured prices (ModelPrice.estimate: a generation
    # is one or the other, never both), each the main loop's and the side
    # requests' together; +side+ is the side requests' share of the total
    # (recap, /btw, ask_model). +known+ is false while generations or side
    # requests ran but none was reported or priced: a cap can't be enforced
    # on such a session. A session with some priced and some unpriced
    # generations reads known (the unpriced ones count 0).
    # Bundles use its methods only, never this constant's name.
    Cost = Data.define(:reported, :estimated, :side, :known) do
      def self.zero = new(reported: 0.0, estimated: 0.0, side: 0.0, known: true)

      # @param totals [Totals] the session's sums, the running turn folded in
      # @param side [SideTotals]
      # @return [Cost]
      def self.of(totals, side)
        side_reported = side.cost_sum.to_f
        side_estimated = side.cost_estimate_sum.to_f
        reported = totals.cost_sum.to_f + side_reported
        estimated = totals.cost_estimate_sum.to_f + side_estimated
        ran = (totals.prompt_sum + totals.completion_sum).positive? || side.requests.positive?
        new(reported: reported, estimated: estimated, side: side_reported + side_estimated,
            known: !ran || reported.positive? || estimated.positive?)
      end

      # @return [Float] reported + estimated, side requests included
      def total = reported + estimated

      def known? = known
    end
  end
end
