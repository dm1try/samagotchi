# frozen_string_literal: true

require_relative "../reply_wait"
require_relative "../session"

module Samagotchi
  class SendCommand
    # Which turn chi send --wait waits for and names in its report:
    # ReplyWait's +turn+ (an enqueued_id; nil: the next reply), +queued+
    # and +ended_before+, and ParentWait's +report_turn_id+ (the turn_id
    # of the --format json line). Each run path builds it its way.
    WaitTarget = Data.define(:turn, :report_turn_id, :queued, :ended_before) do
      def initialize(turn: nil, report_turn_id: nil, queued: false, ended_before: false) = super

      # A --new session's first message. A file-delivered one's own turn
      # (its id also names the outcome of a session command that runs no
      # turn); through the Bridge, the next reply.
      # @param delivered [SessionManager::DeliverResult, nil] nil when the
      #   message started the session itself (no delivery)
      def self.first_message(delivered)
        return new unless delivered

        new(turn: delivered.file? ? delivered.enqueued_id : nil, report_turn_id: delivered.enqueued_id)
      end

      # A message to an existing session. --queue: its own turn, the ack's
      # id, also when the turn running at the check ended before it went in
      # (an idle worker's ack says next_step, and the file still runs as
      # that turn). A file fallback's id names its turn too. Otherwise the
      # next reply, reported as the turn that was running when it went in
      # (+running_turn+, ReplyWait.own_turn), or as its own on an idle one.
      # @param running [Boolean] the session was running when it went in
      def self.message(delivered, queue:, running:, running_turn:)
        turn = delivered.enqueued_id if queue || delivered.file?
        report = if queue then turn
                 elsif running then running_turn
                 else delivered.enqueued_id
                 end
        new(turn: turn, report_turn_id: report, queued: queue && !turn.nil?)
      end

      # --wait with no message: --turn's (+requested+), or the turn running
      # now or whose continue offer stands (ReplyWait.own_turn). Settled
      # (idle, a turn ended, no question standing: a continue offer waits
      # for its answer), its last turn's end is the answer (ended_before);
      # with --turn, when that turn is the last one.
      def self.wait_only(session, session_dir:, requested:)
        settled = session.status == Session::STATUS_IDLE && !session.last_turn.nil? && session.pending_question.nil?
        own = requested ? nil : ReplyWait.own_turn(session, session_dir: session_dir)
        wait_only_of(own_turn: own, settled: settled, last_turn_id: session.last_turn&.enqueued_id, requested: requested)
      end

      # #wait_only from what SessionAccess#prepare_wait read
      # (SessionAccess::WaitStart): its own_turn, settled and last_turn_id.
      def self.after(start, requested:)
        wait_only_of(own_turn: start.own_turn, settled: start.settled, last_turn_id: start.last_turn_id,
                     requested: requested)
      end

      def self.wait_only_of(own_turn:, settled:, last_turn_id:, requested:)
        turn = requested || own_turn
        ended_before = requested ? last_turn_id == requested : settled
        new(turn: turn, report_turn_id: turn || (last_turn_id if settled), ended_before: ended_before)
      end
      private_class_method :wait_only_of
    end
  end
end
