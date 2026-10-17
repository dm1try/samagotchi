# frozen_string_literal: true

module Samagotchi
  class SessionMetrics
    # The sums over a session's finished turn records, kept as running
    # counters (#add folds one record in) and read with the running turn's
    # finished generations folded in (#with_running), so /stats agrees
    # mid-turn. The tool tallies (by tool, aliased, errors) are counted per
    # tool record, not per turn: SessionMetrics keeps those apart.
    class Totals < Data.define(
      :cancellations, :iterations, :gen_ms, :retries, :cuts, :capped, :thinking_dropped,
      :prompt_sum, :completion_sum, :cached_sum, :cache_write_sum, :reprefill_sum, :reasoning_sum,
      :cost_sum, :cost_estimate_sum, :decode_ms_sum, :decode_tokens_sum,
      # The newest speeds a record has, and where the decode one came from.
      :last_decode_tps, :last_prefill_tps, :tps_source,
      # The kinds of counts (server / estimate / mixed) the records came from.
      :token_sources
    )
      # The record keys each sum adds up (a turn record's own names).
      RECORD_SUMS = {
        prompt_sum: :prompt_tokens_sum, completion_sum: :completion_tokens, iterations: :iterations,
        gen_ms: :gen_ms, retries: :retries, cuts: :cuts, capped: :capped, thinking_dropped: :thinking_dropped,
        cached_sum: :cached_tokens_sum,
        cache_write_sum: :cache_write_tokens_sum, reprefill_sum: :reprefill_tokens_sum,
        reasoning_sum: :reasoning_tokens, cost_sum: :cost, cost_estimate_sum: :cost_estimate,
        decode_ms_sum: :decode_ms, decode_tokens_sum: :decode_tokens
      }.freeze

      # The running turn's (TurnState) counters each sum adds while it runs.
      TURN_SUMS = {
        iterations: :iteration_count, gen_ms: :gen_latency_accum, retries: :retries, cuts: :cuts,
        capped: :capped, thinking_dropped: :thinking_dropped, prompt_sum: :prompt_sum, completion_sum: :completion_sum, cached_sum: :cached_sum,
        cache_write_sum: :cache_write_sum, reprefill_sum: :reprefill_sum, reasoning_sum: :reasoning_sum,
        cost_sum: :cost_sum, cost_estimate_sum: :cost_estimate_sum, decode_ms_sum: :decode_ms_sum,
        decode_tokens_sum: :decode_tokens_sum
      }.freeze

      def self.zero
        new(cancellations: 0, **RECORD_SUMS.keys.to_h { |key| [key, 0] }, last_decode_tps: nil,
            last_prefill_tps: nil, tps_source: nil, token_sources: [].freeze)
      end

      # These totals with one finished turn record (symbol keys, as saved;
      # an older record lacks some counts) counted in.
      # @param record [Hash]
      # @return [Totals]
      def add(record)
        sums = RECORD_SUMS.to_h { |sum, key| [sum, public_send(sum) + number(record[key])] }
        sums[:cancellations] = cancellations + 1 if record[:status] == "canceled"
        # The newest speeds a record has (an older record has none).
        if record[:decode_tps].is_a?(Numeric)
          sums[:last_decode_tps] = record[:decode_tps]
          sums[:tps_source] = record[:tps_source]
        end
        sums[:last_prefill_tps] = record[:prefill_tps] if record[:prefill_tps].is_a?(Numeric)
        source = record[:token_source]
        sums[:token_sources] = (token_sources | [source.to_s]).freeze unless source.nil?
        with(**sums)
      end

      # These totals with a later segment's counts and newest speeds.
      # @param later [Totals]
      # @return [Totals]
      def merge(later)
        sums = RECORD_SUMS.keys.to_h { |key| [key, public_send(key) + later.public_send(key)] }
        with(**sums, cancellations: cancellations + later.cancellations,
                     token_sources: (token_sources | later.token_sources).freeze,
                     last_decode_tps: later.last_decode_tps || last_decode_tps,
                     tps_source: later.last_decode_tps ? later.tps_source : tps_source,
                     last_prefill_tps: later.last_prefill_tps || last_prefill_tps)
      end

      # These totals with the running turn's counters so far (its finished
      # generations, calls and iterations) added; the last speeds are the
      # newest a generation reported. nil: these totals.
      # @param turn [TurnState, nil]
      # @return [Totals]
      def with_running(turn)
        return self unless turn

        sums = TURN_SUMS.to_h { |sum, key| [sum, public_send(sum) + (turn.public_send(key) || 0)] }
        if turn.last_decode_tps
          sums[:last_decode_tps] = turn.last_decode_tps
          sums[:tps_source] = turn.tps_source
        end
        sums[:last_prefill_tps] = turn.last_prefill_tps if turn.last_prefill_tps
        sums[:token_sources] = (token_sources + turn.token_sources).freeze
        with(**sums)
      end

      # The snapshot's tokens block.
      # @return [Hash]
      def tokens_block
        {
          prompt_sum: prompt_sum,
          completion_sum: completion_sum,
          cached_sum: cached_sum,
          cache_write_sum: cache_write_sum,
          reprefill_sum: reprefill_sum,
          reasoning_sum: reasoning_sum,
          cost_sum: cost_sum,
          cost_estimate_sum: cost_estimate_sum,
          decode_ms_sum: decode_ms_sum.round,
          decode_tokens_sum: decode_tokens_sum,
          avg_decode_tps: decode_ms_sum.positive? ? (decode_tokens_sum * 1000.0 / decode_ms_sum).round(1) : nil,
          last_decode_tps: last_decode_tps,
          last_prefill_tps: last_prefill_tps,
          tps_source: tps_source,
          source: combined_source
        }
      end

      private

      def number(value)
        value.is_a?(Numeric) ? value : 0
      end

      # server, estimate, or mixed when both kinds of counts (or a turn that
      # was already mixed) are in; nil before any.
      def combined_source
        kinds = token_sources.compact.map(&:to_s)
                             .flat_map { |source| source == "mixed" ? %w[server estimate] : [source] }.uniq
        kinds.size > 1 ? "mixed" : kinds.first
      end
    end
  end
end
