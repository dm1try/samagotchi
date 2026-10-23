# frozen_string_literal: true

require_relative "../session"
require_relative "../parent_report"
require_relative "../chi_invocation"
require_relative "../guardrails/parent_policy"

module Samagotchi
  class SendCommand
    # Why chi send --wait refuses to send into a session a turn runs in: a
    # message that misses the running turn runs next, and the running
    # one's reply would come back as the answer. With --queue the message
    # waits for its own turn, so only a question the turn waits on refuses
    # it (it would queue behind the question). The one wording for the
    # CLI and chi web's wait prepare route, which sends these fields so a
    # chi --remote client words it with its own commands (#message's via:).
    # @!attribute error [String] "waiting" (a question or an approval waits
    #   on chi answer) or "busy" (a turn runs)
    # @!attribute session_id [String]
    # @!attribute question [PendingQuestion, nil] what waits ("waiting")
    # @!attribute strategy [Guardrails::ParentPolicy::Strategy, nil] what a
    #   parent may pick on it: config.yml tightened by the session's own
    #   parent_answers
    Busy = Data.define(:error, :session_id, :question, :strategy) do
      # @param session [Session] the session as just read
      # @param owner [OwnerLock::Owner, nil] the worker or REPL that owns it
      # @param queue [Boolean] chi send --queue
      # @return [Busy, nil] nil when the message may go in
      def self.for(session, owner:, queue:)
        return nil unless session.status == Session::STATUS_RUNNING && owner

        waiting = session.waiting_question(live: owner.worker?)
        return nil if queue && !waiting
        return new(error: "busy", session_id: session.id, question: nil, strategy: nil) unless waiting

        new(error: "waiting", session_id: session.id, question: session.pending_question,
            strategy: Guardrails::ParentPolicy.for_session(session))
      end

      # What the user is told, after the session's short id.
      # @param via [ChiInvocation] how its commands are spelled
      def message(via: ChiInvocation::HERE)
        return "busy: a turn is running; wait or #{via.remote? ? "open it in #{via.web}" : "attach"}" unless error == "waiting"

        id = session_id
        # The whole question (its options, its tags) for what a parent may
        # give.
        q = ParentReport.question(question, strategy: strategy)
        answer = ParentReport.answer_with(id, q, via: via)
        if ParentReport.approval?(q)
          "waiting for an approval: #{ParentReport.approval_advice(q, strategy: strategy)} (#{answer})"
        else
          "waiting for an answer: #{answer} (or --text); #{via.shows(id)} shows it"
        end
      end
    end
  end
end
