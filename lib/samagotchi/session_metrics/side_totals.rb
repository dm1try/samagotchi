# frozen_string_literal: true

require_relative "../model_price"

module Samagotchi
  class SessionMetrics
    # The sums over a session's side requests (SideUsage: an idle recap, a
    # plugin's ctx.ask_model such as /btw), kept apart from its turns'
    # Totals: the snapshot's and analytics.json's +side+ block, never in
    # +tokens+ or +model_segments+. They have no records: the block itself
    # is saved and loaded (#to_h, .from_saved).
    # +cost_sum+ is nil until a request reports a cost (a reported 0
    # included), +cost_estimate_sum+ 0 until one is estimated from a price
    # (ModelPrice.estimate, the turns' rule). +by_kind+ is a frozen Hash
    # kind => {requests:, cost_sum:, cost_estimate_sum:} in first-seen order.
    class SideTotals < Data.define(:requests, :prompt_sum, :completion_sum, :cached_sum, :cache_write_sum,
                                   :reasoning_sum, :cost_sum, :cost_estimate_sum, :by_kind)
      # The counts summed as they are (the costs and by_kind apart).
      COUNTS = %i[requests prompt_sum completion_sum cached_sum cache_write_sum reasoning_sum].freeze

      def self.zero
        new(**COUNTS.to_h { |key| [key, 0] }, cost_sum: nil, cost_estimate_sum: 0, by_kind: {}.freeze)
      end

      # The block as analytics.json saved it (string keys): a non-Hash is
      # zero totals, a missing or non-numeric count 0, a missing or null
      # cost_sum nil.
      # @param hash [Hash, nil]
      # @return [SideTotals]
      def self.from_saved(hash)
        return zero unless hash.is_a?(Hash)

        hash = hash.transform_keys(&:to_s)
        kinds = hash["by_kind"].is_a?(Hash) ? hash["by_kind"] : {}
        new(**COUNTS.to_h { |key| [key, count(hash[key.to_s])] }, cost_sum: cost(hash["cost_sum"]),
                                                                  cost_estimate_sum: number(hash["cost_estimate_sum"]),
                                                                  by_kind: kinds.each_with_object({}) do |(kind, row), rows|
                                                                    row = row.is_a?(Hash) ? row.transform_keys(&:to_s) : {}
                                                                    rows[kind.to_s] = { requests: count(row["requests"]), cost_sum: cost(row["cost_sum"]),
                                                                                        cost_estimate_sum: number(row["cost_estimate_sum"]) }.freeze
                                                                  end.freeze)
      end

      # These totals with one side request counted in.
      # @param usage [SideUsage]
      # @return [SideTotals]
      def add(usage)
        estimate = ModelPrice.estimate(usage.price, reported_cost: usage.cost, prompt_tokens: usage.prompt_tokens,
                                                    cached_tokens: usage.cached_tokens,
                                                    cache_write_tokens: usage.cache_write_tokens,
                                                    completion_tokens: usage.completion_tokens)
        one = { requests: 1, cost_sum: usage.cost&.to_f, cost_estimate_sum: estimate || 0 }
        kind = usage.kind.to_s
        rows = by_kind.merge(kind => sum_row(by_kind[kind], one))
        with(requests: requests + 1, prompt_sum: prompt_sum + usage.prompt_tokens.to_i,
             completion_sum: completion_sum + usage.completion_tokens.to_i,
             cached_sum: cached_sum + usage.cached_tokens.to_i,
             cache_write_sum: cache_write_sum + usage.cache_write_tokens.to_i,
             reasoning_sum: reasoning_sum + usage.reasoning_tokens.to_i,
             cost_sum: add_cost(cost_sum, one[:cost_sum]),
             cost_estimate_sum: cost_estimate_sum + one[:cost_estimate_sum], by_kind: rows.freeze)
      end

      # These totals with +other+'s added (a loaded block and the requests
      # counted before the load); the kinds in first-seen order, these first.
      # @param other [SideTotals]
      # @return [SideTotals]
      def merge(other)
        rows = other.by_kind.each_with_object(by_kind.dup) { |(kind, row), all| all[kind] = sum_row(all[kind], row) }
        with(**COUNTS.to_h { |key| [key, public_send(key) + other.public_send(key)] },
             cost_sum: add_cost(cost_sum, other.cost_sum),
             cost_estimate_sum: cost_estimate_sum + other.cost_estimate_sum, by_kind: rows.freeze)
      end

      def empty? = requests.zero?

      # The snapshot's side block (symbol keys; by_kind keyed by kind).
      # @return [Hash]
      def to_h
        counts = COUNTS.to_h { |key| [key, public_send(key)] }
        counts.merge(cost_sum: cost_sum, cost_estimate_sum: cost_estimate_sum, by_kind: by_kind.transform_values(&:dup))
      end

      def self.count(value) = value.is_a?(Numeric) ? value.to_i : 0

      def self.number(value) = value.is_a?(Numeric) ? value : 0

      def self.cost(value) = value.is_a?(Numeric) ? value : nil

      private_class_method :count, :number, :cost

      private

      def sum_row(row, one)
        return one.dup.freeze unless row

        { requests: row[:requests] + one[:requests], cost_sum: add_cost(row[:cost_sum], one[:cost_sum]),
          cost_estimate_sum: row[:cost_estimate_sum] + one[:cost_estimate_sum] }.freeze
      end

      # nil + nil stays nil (no cost reported yet); a reported one sums.
      def add_cost(left, right)
        return left if right.nil?
        return right if left.nil?

        left + right
      end
    end
  end
end
