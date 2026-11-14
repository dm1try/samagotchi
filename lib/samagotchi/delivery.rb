# frozen_string_literal: true

module Samagotchi
  # What a message sent to a running turn does when it arrives: wait for the
  # turn's next step boundary and go in there (the default), cut the running
  # generation short to go in now, or wait for the turn to end and run as a
  # turn of its own (see docs/configuration.md). The field travels as the
  # wire value name; a sender that names nothing gets the default.
  module Delivery
    NEXT_STEP = "next_step"
    CUT = "cut"
    QUEUE = "queue"
    VALUES = [NEXT_STEP, CUT, QUEUE].freeze

    # A body's delivery field as one of VALUES. Missing, empty or unknown:
    # NEXT_STEP (an older client, a hand-written request).
    # @param raw [Object] the wire value
    # @return [String] one of VALUES
    def self.parse(raw)
      raw.is_a?(String) && VALUES.include?(raw) ? raw : NEXT_STEP
    end

    # Why a request body's delivery field can't be taken, as {error:,
    # detail:} for a 400, or nil when it can. The Bridge and the web's
    # POST /turn both ask this, so they refuse the same values. A missing
    # or unknown string is not refused: it is the default (#parse).
    # @param raw [Object] the wire value
    # @return [Hash, nil]
    def self.refusal(raw)
      return nil if raw.nil?
      return { error: "bad_delivery", detail: "delivery must be a string" } unless raw.is_a?(String)

      nil
    end

    # The worker sidecar feature (Bridge::FEATURES) of a worker that runs
    # all three values. One without it (before 0.64) ignores QUEUE, or
    # refuses it with a 400 delivery_unavailable, so a sender checks it
    # before sending a queue (SessionManager.deliver_turn, the attached TUI).
    QUEUE_FEATURE = "delivery"

    # The refusal for a queue a worker without QUEUE_FEATURE would steer
    # (SessionManager.deliver_turn answers it as a 409). P0-P2 workers
    # answer the same error code for a queue, with their own detail.
    QUEUE_UNAVAILABLE = {
      "error" => "delivery_unavailable",
      "detail" => "this session's worker predates queueing, so the message would steer the running turn; " \
                  "restart it (chi sessions restart ID, or the web's update badge) and send again"
    }.freeze

    # A worker that runs participants' turns inside a boundary
    # (Bridge::FEATURES): one without it would run theirs with the owner's
    # tools. Kept on the wire for an older chi web; this chi checks
    # PAIR_FEATURE, which every worker with this one's boundary has.
    REVIEW_FEATURE = "review_turns"

    # A worker that runs a participant's turn as a pair turn under the
    # owner's guardrails (Guardrails::PairBoundary). One without it would
    # run it as a read-only review turn, which this chi doesn't run: chi web
    # sends it no participant's turn (PAIR_UNAVAILABLE) and no invite is
    # issued for its session (ShareTerms.of) until it restarts.
    # Workers advertise REVIEW_FEATURE too: an older chi web refuses
    # participants' turns to a worker without it.
    PAIR_FEATURE = "pair_turns"
    # A worker that reads a participant's client id as participant:<id>
    # (ClientId::PARTICIPANT_PREFIX). One without it reads only review:<id>
    # (an unknown id to it: never the owner's, but its lines' source would
    # be automatic:… and a participant's Verify fresh child would ring its
    # parent), so chi web sends it the old id (SessionManager's delivery).
    PARTICIPANT_ID_FEATURE = "participant_client_id"
    # The one sentence for a live worker without PAIR_FEATURE; each caller
    # adds what to do (PAIR_UNAVAILABLE, ShareTerms::OLDER_WORKER_REFUSAL).
    OLDER_THAN_PAIR = "this session's worker is too old to run a participant's turn"
    PAIR_UNAVAILABLE = {
      "error" => "pair_unavailable",
      "detail" => "#{OLDER_THAN_PAIR}: the owner must restart it (chi sessions restart ID, or the web's update badge)"
    }.freeze
    # The worker sidecar feature (Bridge::FEATURES) of a worker whose
    # participant's message sent while their own turn runs goes in at its
    # next step (Bridge#same_author_steer?, SessionInbox.turn_end_data?'s
    # running author). One without it queues every participant message,
    # which is safe: the feature only says what will really happen (chi
    # web's ack, the page's delivery line).
    OWN_TURN_STEER_FEATURE = "participant_steer"
    # The worker sidecar feature (Bridge::FEATURES) of a worker whose cancel
    # compares the turn_id it names under its lock (TurnState#cancel!, 409
    # turn_mismatch). One without it may ignore the id and cancel whatever
    # runs, so chi web relays a participant's cancel only to a worker with it
    # (ParticipantAccess#participant_cancel).
    CANCEL_TURN_ID_FEATURE = "cancel_turn_id"

    # Whether it is the one every sender defaulting to a step boundary uses.
    def self.next_step?(value) = parse(value) == NEXT_STEP

    # Whether the running turn should be cut for it (only when the message
    # asks: nothing else cuts).
    def self.cut?(value) = parse(value) == CUT

    # Whether it waits for the turn to end and runs as a turn of its own.
    def self.queue?(value) = parse(value) == QUEUE
  end
end
