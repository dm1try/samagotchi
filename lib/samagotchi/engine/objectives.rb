# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's objectives: their view announced when it changed, Check
    # this's side request, the model's proposals kept as cards until the turn
    # is over, System 1's audit of them (ObjectivesAudit). Writes
    # @objectives_announced, @objectives_audit; reads @objective_proposals
    # under @objective_proposals_mutex, @session, @side_judgments.
    module ObjectivesPart
      # The session's objectives as the page draws them (Objectives.view), when
      # that differs from the last announced: after an edit (its file written,
      # pending), once a list note is in, at a turn's end (its moves) and after
      # a rollback. A session with no list announces nothing. It only informs:
      # a failure is logged, never the turn's.
      def announce_objectives(session = @session)
        return unless session

        synchronize_events do
          view = Objectives.view(session.id, session.messages, state_dir: session_state_dir, running: live_conversation&.dup)
          next if view.nil? || view == @objectives_announced

          @objectives_announced = view
          announce({ type: :objectives_updated, session_id: session.id, **view })
        end
      rescue StandardError => e
        Log.warn(:turn, "objectives_announce_failed", error: e.class.name, msg: e.message)
      end

      # Check this (ObjectivesCheck)'s one side request. Its usage is in the
      # session's side line. Raises as ctx.ask_model's request does.
      # @param request [Array<Hash>] chat messages
      # @param model [String, nil] a configured model; nil: the session's
      # @return [String] the answer
      def ask_objective_check(request, model:)
        ask_side_model(request, timeout: ObjectivesCheck::TIMEOUT_SECONDS, max_tokens: ObjectivesCheck::MAX_TOKENS,
                                cancel_controller: nil, model: model, source: ObjectivesCheck::SOURCE)
      end

      # A change the model proposes (the objectives tool), kept until the turn
      # is over, as #context_choice's cards are: a card shown then is a quiet one, between turns, with its Apply kept
      # over a restart (CardStore), not a running turn's that says it waits on the
      # user. The same change twice in a turn is one card.
      # @return [Boolean] false past Objectives::PROPOSALS_PER_TURN
      def propose_objective(proposal)
        @objective_proposals_mutex.synchronize do
          next true if @objective_proposals.any? { |p| p.line == proposal.line }
          next false if @objective_proposals.size >= Objectives::PROPOSALS_PER_TURN

          @objective_proposals << proposal
          true
        end
      end

      def show_objective_proposals
        drain_objective_proposals.each do |proposal|
          id = "objectives-#{SecureRandom.hex(4)}"
          show_card(source: Objectives::SOURCE, id: id, title: proposal.title, body: proposal.body,
                    actions: [{ label: "Apply", command: proposal.action_line(id) },
                              { label: "Dismiss", command: "/objectives --card #{id} dismiss" }])
        end
      rescue StandardError => e
        Log.warn(:turn, "objectives_proposal_failed", error: e.class.name, msg: e.message)
      end
      private :show_objective_proposals

      # A turn that did not complete (canceled, failed) takes its proposals
      # off the buffer without showing them: their Apply card would sit after a
      # turn whose `objectives propose` call is not in the history (a rollback
      # after Ctrl-C drops it), and leaving them in the buffer would show them
      # at the end of the next turn.
      def discard_objective_proposals(turn)
        dropped = drain_objective_proposals
        Log.info(:turn, "objectives_proposals_dropped", count: dropped.size, outcome: turn.outcome.to_s) unless dropped.empty?
      end
      private :discard_objective_proposals

      def drain_objective_proposals
        @objective_proposals_mutex.synchronize { @objective_proposals.slice!(0..) }
      end
      private :drain_objective_proposals

      private

      # System 1 on the objectives, in audit (ObjectivesAudit): the owner's turns
      # only, and for a message a person's: a reminder's or a delegate's prompt isn't one.
      def audit_objectives_incoming(turn)
        return unless turn.prompt.is_a?(String) && turn.origin.human? && OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        objectives_audit.incoming(turn.session, turn.prompt)
      end
      private :audit_objectives_incoming

      def audit_objectives_outgoing(turn, result)
        return unless OwnerPrompt.turn?(session: turn.session, author: turn.origin.author)

        objectives_audit.outgoing(turn.session, result.text)
      end
      private :audit_objectives_outgoing

      # With saving off nothing would come of an ask, so none is made.
      def objectives_audit
        @objectives_audit ||= ObjectivesAudit.new(
          side: @side_judgments, state_dir: -> { session_state_dir },
          client_for: lambda do |judgment, session|
            next nil unless system_one_runs.on?

            system_one_recording(SystemOne::Client.from_config(host_registry: @host_registry, mode: ObjectivesAudit::MODE, tag: :system_one),
                                 judgment, session)
          end
        )
      end
      private :objectives_audit
    end
  end
end
