# frozen_string_literal: true

module Samagotchi
  class Schedules
    # The run history (docs/scheduling.md, `chi schedule show`): each entry
    # keeps its last HISTORY_MAX outcomes in `history`, newest last, rows
    # {at:, status:, detail:, session_id:}. One writer per status, each
    # appending once per event:
    #   skipped, failed — #skipped / #failed (the helpers, never their
    #     callers), and #run_now's refusal of a disabled entry (no counters);
    #     a budget turn-off is that row, its detail "disabled: <reason>"
    #   fired — #finish_pending (a firing that settles) and #record's "fired"
    #   missed — #reschedule
    #   enabled, disabled — #change (the owner's; never a budget turn-off)
    #   edited — #edit, its detail the changed fields
    # A pending firing writes no row: it is not an outcome yet.
    module HistoryPart
      HISTORY_MAX = 20
      # A detail is clipped to this many characters (an exception's message
      # or a turn's reason can be long): with the row's other fields (~120
      # bytes) an entry's history stays under about 20 × 320 bytes, 6.4 KB.
      DETAIL_MAX = 200

      # The rows as JSON hands them back (string keys) or as written (symbol
      # keys): symbol keys, non-rows dropped.
      # @return [Array<Hash>]
      def self.rows(value)
        Array(value).filter_map { |row| row.transform_keys(&:to_sym) if row.is_a?(Hash) }
      end

      private

      # A skip's or a failure's row (+before+ the call, +after+ it), and the
      # disabled notice when this call turned the entry off by its budget.
      # Its session: the pending firing's, else the head.
      def recorded(before, after, status, reason, now)
        off = budget_turned_off?(before, after, status)
        noticed = with_disabled_notice(before, after, status, reason, now)
        with_history(noticed, status, off ? "disabled: #{reason}" : reason, at: now,
                                                                            session_id: before.pending_session_id || before.head)
      end

      # +entry+ with one row more, the oldest dropped past HISTORY_MAX.
      def with_history(entry, status, detail, at:, session_id: nil)
        clipped = detail.nil? ? nil : detail.to_s[0, DETAIL_MAX]
        row = { at: at.utc.iso8601, status: status, detail: clipped, session_id: session_id }
        entry.with(history: (HistoryPart.rows(entry.history) + [row]).last(HISTORY_MAX))
      end
    end
  end
end
