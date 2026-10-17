# frozen_string_literal: true

require_relative "totals"

module Samagotchi
  class SessionMetrics
    # A run of consecutive turns on one model (their records' model_ref, the
    # asked host:model): /stats and the web's ctx/cost tooltip split the
    # session's tokens, cost and speed by these, in order, so A -> B -> A is
    # three. Derived from the turn records as they are counted, never saved
    # on their own. A record with no ref (a turn stopped before it asked a
    # model) joins the segment before it; records with none before the first
    # one that names a model (a session older than model_ref) make one
    # leading segment with no ref.
    #
    # +prefill_tokens+ / +prefill_cost_estimate+: what the segment's first
    # turn prefilled on its model after the switch (the records'
    # switch_prefill_*), 0 / nil for none.
    class ModelSegment < Data.define(:model_ref, :started_at, :ended_at, :turns, :totals, :prefill_tokens,
                                     :prefill_cost_estimate)
      # The most rows a snapshot sends: older ones fold into one.
      CAP = 6

      # A segment opened by +record+ (its first turn).
      # @param record [Hash] a turn record (symbol keys)
      # @return [ModelSegment]
      def self.open(record)
        ref = record[:model_ref].to_s
        new(model_ref: ref.empty? ? nil : ref, started_at: record[:started_at], ended_at: nil, turns: 0,
            totals: Totals.zero, prefill_tokens: 0, prefill_cost_estimate: nil).add(record)
      end

      # The segment a snapshot shows for the running turn when it is on
      # another model than the last segment's: no finished turn yet.
      # @param ref [String]
      # @param started_at [String, nil]
      # @return [ModelSegment]
      def self.empty(ref, started_at)
        new(model_ref: ref, started_at: started_at, ended_at: nil, turns: 0, totals: Totals.zero, prefill_tokens: 0,
            prefill_cost_estimate: nil)
      end

      # Whether +record+ starts a new segment after this one: it names a
      # model, and another one than this segment's.
      def self.splits?(segment, record)
        ref = record[:model_ref].to_s
        segment.nil? || (!ref.empty? && segment.model_ref != ref)
      end

      # This segment with one more finished turn record.
      # @return [ModelSegment]
      def add(record)
        tokens = record[:switch_prefill_tokens]
        estimate = record[:switch_prefill_cost_estimate]
        with(ended_at: record[:completed_at] || ended_at, turns: turns + 1, totals: totals.add(record),
             prefill_tokens: prefill_tokens + (tokens.is_a?(Numeric) ? tokens : 0),
             prefill_cost_estimate: estimate.is_a?(Numeric) ? prefill_cost_estimate.to_f + estimate : prefill_cost_estimate)
      end

      # This segment with the running turn (SessionMetrics::TurnState) in:
      # its finished generations and the prefill it recorded so far; it
      # runs on, so it has no end.
      # @return [ModelSegment]
      def with_running(turn)
        estimate = turn.switch_prefill_cost_estimate
        with(ended_at: nil, turns: turns + 1, totals: totals.with_running(turn),
             prefill_tokens: prefill_tokens + turn.switch_prefill_tokens.to_i,
             prefill_cost_estimate: estimate ? prefill_cost_estimate.to_f + estimate : prefill_cost_estimate)
      end

      # The row a snapshot carries (JSON-ready). +ended_at+ nil: the segment
      # runs now.
      # @return [Hash]
      def to_h
        tokens = totals.tokens_block
        {
          model_ref: model_ref, started_at: started_at, ended_at: ended_at, turns: turns,
          **tokens.slice(:prompt_sum, :completion_sum, :cached_sum, :cost_sum, :cost_estimate_sum, :avg_decode_tps,
                         :last_decode_tps, :tps_source),
          prefill_tokens: prefill_tokens, prefill_cost_estimate: prefill_cost_estimate
        }
      end

      # The rows of +segments+ a snapshot sends: none for fewer than 2 (one
      # model: the plain totals say it all); over CAP, the oldest fold into
      # one row with no ref that says how many it holds (folded_segments).
      # @param segments [Array<ModelSegment>]
      # @return [Array<Hash>]
      def self.rows(segments)
        return [] if segments.size < 2
        return segments.map(&:to_h) if segments.size <= CAP

        older = segments.first(segments.size - CAP + 1)
        folded = older.drop(1).reduce(older.first.with(model_ref: nil)) do |sum, segment|
          sum.merge(segment)
        end
        [folded.to_h.merge(folded_segments: older.size), *segments.last(CAP - 1).map(&:to_h)]
      end

      # This segment and a later one as one row (the folded older ones).
      # @return [ModelSegment]
      def merge(later)
        estimate = [prefill_cost_estimate, later.prefill_cost_estimate].compact
        with(ended_at: later.ended_at, turns: turns + later.turns, totals: totals.merge(later.totals),
             prefill_tokens: prefill_tokens + later.prefill_tokens, prefill_cost_estimate: estimate.empty? ? nil : estimate.sum)
      end
    end
  end
end
