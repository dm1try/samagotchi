# frozen_string_literal: true

require_relative "../session"
require_relative "../parent_report"
require_relative "../guardrails/parent_policy"

module Samagotchi
  class SendCommand
    # Why chi send --wait refuses to send into a session a turn runs in: a
    # message that misses the running turn runs next, and the running
    # one's reply would come back as the answer. With --queue the message
    # waits for its own turn, so only a question the turn waits on refuses
    # it (it would queue behind the question). The one wording for the
    # CLI and chi web's wait prepare route.
    # @!attribute error [String] "waiting" (a question or an approval waits
    #   on chi answer) or "busy" (a turn runs)
    # @!attribute message [String] what the user is told, after the
    #   session's short id
    Busy = Data.define(:error, :message) do
      # @param session [Session] the session as just read
      # @param owner [OwnerLock::Owner, nil] the worker or REPL that owns it
      # @param queue [Boolean] chi send --queue
      # @return [Busy, nil] nil when the message may go in
      def self.for(session, owner:, queue:)
        return nil unless session.status == Session::STATUS_RUNNING && owner

        waiting = session.waiting_question(live: owner.worker?)
        return nil if queue && !waiting
        return new(error: "busy", message: "busy: a turn is running; wait or attach") unless waiting

        id = session.id
        # The whole question (its options, its tags) for what a parent may
        # give: config.yml tightened by the session's own parent_answers.
        strategy = Guardrails::ParentPolicy.for_session(session)
        question = ParentReport.question(session.pending_question, strategy: strategy)
        message = if ParentReport.approval?(waiting)
                    "waiting for an approval: #{ParentReport.approval_advice(question, strategy: strategy)} " \
                      "(#{ParentReport.answer_with(id, question)})"
                  else
                    "waiting for an answer: #{ParentReport.answer_with(id, question)} (or --text); " \
                      "chi --attach #{id} shows it"
                  end
        new(error: "waiting", message: message)
      end
    end
  end
end
