# frozen_string_literal: true

require_relative "../log"
require_relative "../peer_receipts"

module Samagotchi
  class Worker
    # A peer's mail on the worker's side: the absorb and the mail wake turn
    # it may start (WorkerInbound#absorb_mail), the hold a pass gives, and
    # the receipts' end of every turn (PeerReceipts#turn_ended). Reads
    # @inbound, @exit_claim and @peer_receipts, and @unmarked_this_turn
    # (#run_wake sets it). See docs/internals/peers.md.
    module MailPart
      private

      # A peer's mail (WorkerInbound#absorb_mail), and the mail wake turn it
      # may start. A failure to read or write it (or in that turn) is logged:
      # the next pass tries again.
      # @param hold [Symbol, nil] why a wake can't run now (MailPart::CALLER_HOLDS)
      # @return [Boolean] whether a wake turn ran
      def absorb_mail(hold: nil)
        mail_wake = @inbound.absorb_mail(hold: hold)
        return false unless mail_wake

        run_mail_wake_turn(mail_wake)
        true
      rescue SystemCallError, IOError => e
        Log.exception(:worker, "mail_failed", e)
        false
      end

      # Why a pass's mail can't wake chi: an exit a client asked for, or
      # input queued (its turn reads the mail); nil when it may.
      def pass_hold
        return :exit if @exit_claim.taken?

        :queued unless nothing_queued?
      end

      # A turn +id+ starts: the peer notes waiting are read by it
      # (PeerReceipts#turn_started); whether a wake's note goes back plain
      # (#run_wake sets it) starts false.
      # Logged, never raised: the turn runs without it.
      def peer_turn_started(id)
        @unmarked_this_turn = false
        @peer_receipts.turn_started(id)
      rescue SystemCallError, IOError => e
        Log.exception(:worker, "peer_receipts_failed", e)
      end

      # The receipts the turn +id+ woke or read (PeerReceipts#turn_ended): how
      # it ended, or held when a wake's note went back plain. Logged, never
      # raised: the turn's own save comes next.
      def peer_receipts_ended(id, result, error)
        outcome = if error then :failed
                  elsif result&.canceled? then :canceled
                  else :completed
                  end
        @peer_receipts.turn_ended(id, outcome: outcome, unmarked: @unmarked_this_turn)
      rescue SystemCallError, IOError => e
        Log.exception(:worker, "peer_receipts_failed", e)
      end
    end
  end
end
