# frozen_string_literal: true

require_relative "../delivery"
require_relative "../session"

module Samagotchi
  module ReplyWait
    # Which turn a reply wait waits for, and how: the one binding every
    # caller builds (chi send --wait, chi answer, a participant's wait, the
    # delegate tools and a delegate report), each with its constructor.
    # #to_h is ReplyWait.call's kwargs (+cursor+, +baseline+,
    # +owner_grace+, +turn+, +queued+, +ended_before+: ReplyWait.call's
    # parameters say what each means); +report_turn_id+ (the turn_id of
    # --format json's line, ParentWait's) is read on its own.
    Target = Data.define(:turn, :report_turn_id, :queued, :ended_before, :cursor, :baseline, :owner_grace) do
      def initialize(turn: nil, report_turn_id: nil, queued: false, ended_before: false, cursor: nil, baseline: nil,
                     owner_grace: nil)
        super
      end

      # A --new session's first message: its own turn, the ack's id (a
      # file-delivered one's also names the outcome of a session command
      # that runs no turn), so a worker that dies in it and the next one's
      # settle end the wait (TurnCheckpoint.settled_turn). A message merged
      # into a turn starting then falls back to that turn's reply
      # (ReplyWait's turn: without queued:); no id (an older worker), the
      # next reply. A prompt the session was created with has no delivery:
      # its turn is the id the create gave it (+direct_turn+,
      # Session#first_turn_id), and nothing can merge into it, so the wait
      # is for that turn alone (ReplyWait's queued:).
      # @param start [SessionAccess::WaitStart] prepare_wait's (its cursor
      #   and baseline)
      # @param delivered [SessionManager::DeliverResult, nil] nil when the
      #   message started the session itself (no delivery)
      # @param direct_turn [String, nil] that first turn's id, for a direct
      #   start
      def self.first_message(start, delivered, direct_turn: nil)
        reads = { cursor: start&.cursor, baseline: start&.baseline, owner_grace: ReplyWait::GONE_AFTER }
        return new(**reads) unless delivered || !direct_turn.to_s.strip.empty?

        return new(turn: direct_turn, report_turn_id: direct_turn, queued: true, **reads) if delivered.nil?

        new(turn: delivered.enqueued_id, report_turn_id: delivered.enqueued_id, **reads)
      end

      # A message to an existing session: its own turn, the ack's id. With
      # --queue it runs as that turn, also when the turn running at the
      # check ended before it went in (an idle worker's ack says next_step,
      # and the file still runs as that turn). A plain one may run as its
      # own turn or merge into a running one (a session left running by a
      # dead worker, the busy check's owner gone; or a turn starting then):
      # that turn's end is its answer (ReplyWait's follow_merge). A plain
      # message the worker queued (its ack says queue: a participant's
      # review turn was running, which takes no steer) is a --queue's. An
      # ack with no id (an older worker): the next reply, reported as the
      # turn that was running when it went in (start's own_turn).
      # @param start [SessionAccess::WaitStart] read before it went in (its
      #   running says the session was running then)
      def self.message(start, delivered, queue:)
        queue ||= delivered.delivery == Delivery::QUEUE
        turn = delivered.enqueued_id
        new(turn: turn, report_turn_id: turn || (start.own_turn if start.running && !queue), queued: queue && !turn.nil?,
            cursor: start.cursor, baseline: start.baseline, owner_grace: ReplyWait::GONE_AFTER)
      end

      # --wait with no message: --turn's (+requested+), or the turn running
      # now or whose continue offer stands (start's own_turn,
      # ReplyWait.own_turn). Settled (idle, a turn ended, no question
      # standing: a continue offer waits for its answer), its last turn's
      # end is the answer (ended_before); with --turn, when that turn is the
      # last one. A session no worker runs waits for whatever wakes one (no
      # owner_grace).
      # @param start [SessionAccess::WaitStart]
      def self.wait_only(start, requested:)
        turn = requested || start.own_turn
        ended_before = requested ? start.last_turn_id == requested : start.settled
        new(turn: turn, report_turn_id: turn || (start.last_turn_id if start.settled), ended_before: ended_before,
            cursor: start.cursor, baseline: start.baseline, owner_grace: start.live ? ReplyWait::GONE_AFTER : nil)
      end

      # chi answer: the turn the question is about (start's own_turn: the
      # one running, or the one whose continue offer stands), else the next
      # reply.
      def self.answer(start)
        new(turn: start.own_turn, report_turn_id: start.own_turn, cursor: start.cursor, baseline: start.baseline,
            owner_grace: ReplyWait::GONE_AFTER)
      end

      # A participant's --wait -m: their review turn just queued (+turn+),
      # as --wait --turn T (their wait routes take only a turn of theirs).
      def self.participant(start, turn:) = wait_only(start, requested: turn)

      # A delegate's wait (DelegateWait, a delegate report) from the
      # parent's DelegateCursor: the newest reply it was given, the child as
      # it was then, and the turn a follow-up joined. The child's first turn
      # (Session#first_turn_id: the prompt it was spawned with) runs as its
      # own and nothing merges into it, so a wait bound to it is queued.
      # @param cursor [Tools::DelegateCursor]
      # @param child [Session, nil] the child as read now (its first_turn_id)
      # @param owner_grace [Numeric, nil] nil: no gone check (a report's
      #   look)
      def self.from_cursor(cursor, child:, owner_grace: nil)
        first = child&.first_turn_id
        new(turn: cursor.turn, cursor: cursor.reply_file, baseline: cursor.baseline, owner_grace: owner_grace,
            queued: !cursor.turn.to_s.empty? && cursor.turn == first)
      end

      # ReplyWait.call's kwargs (report_turn_id is ParentWait's, not one).
      def to_h = { cursor: cursor, baseline: baseline, owner_grace: owner_grace, turn: turn, queued: queued,
                   ended_before: ended_before }
    end
  end
end
