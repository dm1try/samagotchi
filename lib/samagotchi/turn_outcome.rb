# frozen_string_literal: true

require_relative "session_inbox"
require_relative "turn_checkpoint"

module Samagotchi
  # What a queued turn came to, from its files: whether it left a reply
  # (SessionInbox.reply_for) and the turn it settled as (the session's
  # last_turn when it is that turn, else TurnCheckpoint.settled_turn). A
  # schedule's pending firing reads it (Schedules#resolve_pending, which
  # keeps its own order around it: the reply, its question window, the turn,
  # expiry).
  # @!attribute replied [Boolean] a reply file names the turn
  # @!attribute turn [LastTurn, nil] the settled turn, nil while it runs
  TurnOutcome = Data.define(:replied, :turn) do
    # @param session [Session] the session the turn was queued in
    # @param turn_id [String] its enqueued id
    # @param session_dir [String] that session's sidecar dir
    # @return [TurnOutcome]
    def self.for(session, turn_id, session_dir:)
      turn = session.last_turn if session.last_turn&.enqueued_id == turn_id
      turn ||= TurnCheckpoint.settled_turn(session_dir, turn_id)
      new(replied: !SessionInbox.reply_for(session_dir, turn_id).nil?, turn: turn)
    end

    def settled? = replied || !turn.nil?

    # The settled turn completed (the turn alone: a reply is #replied).
    def completed? = turn&.outcome == "completed"

    # The words of a settled outcome, nil before it settles.
    # @return [String, nil]
    def detail
      return nil unless settled?
      return "turn completed" if replied || completed?

      reason = [turn.outcome, turn.error_kind, turn.cancel_reason, turn.stopped_by].compact.join(": ")
      "turn #{reason.empty? ? "did not complete" : reason}"
    end
  end
end
