# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's objectives (TurnStages::Objectives, forwarded): the view
    # announced when it changed, the model's proposals kept as cards until
    # the turn is over, System 1's audit of them (ObjectivesAudit); and
    # Check this's and the tracker's side requests. Reads @objectives_stage, @side_judgments,
    # @host_registry, @session.
    module ObjectivesPart
      # The session's objectives as the page draws them, when that differs
      # from the last announced (TurnStages::Objectives#announce), from any
      # thread: end_turn's step, a command, Check this's thread, a note,
      # a rollback. Under the event lock, which guards the last view: the
      # sessions dir and the running turn's conversation read there, the
      # event announced in the same step. It only informs: a failure is
      # logged, never raised.
      def announce_objectives(session = @session)
        return unless session

        synchronize_events do
          event = @objectives_stage.announce(session, state_dir: session_state_dir, running: live_conversation)
          announce(event) if event
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

      # The tracker (ObjectivesTrack)'s one side request, under its own kind so
      # /stats counts it apart. +cancel_controller+: the automatic read's, which
      # the owner's next turn cancels (raises LLM::RequestCancelled then).
      # @return [String] the answer
      def ask_objective_track(request, model:, cancel_controller: nil)
        ask_side_model(request, timeout: ObjectivesTrack::TIMEOUT_SECONDS, max_tokens: ObjectivesTrack::MAX_TOKENS,
                                cancel_controller: cancel_controller, model: model, source: ObjectivesTrack::SOURCE)
      end

      # A change the model proposes (the objectives tool), kept until the turn
      # is over (TurnStages::Objectives#propose).
      # @return [Boolean] false past Objectives::PROPOSALS_PER_TURN
      def propose_objective(proposal) = @objectives_stage.propose(proposal)

      private

      # The objectives' stage (TurnStages::Objectives).
      attr_reader :objectives_stage

      # However +turn+ ended (run_turn's ensure, after the turn flag is
      # released): a completed turn's proposal cards shown
      # (TurnStages::Objectives#finally). A card that fails is logged.
      def show_objective_proposals(turn)
        @objectives_stage.finally(turn).each { |card| show_card(**card) }
      rescue StandardError => e
        Log.warn(:turn, "objectives_proposal_failed", error: e.class.name, msg: e.message)
      end

      # After a completed turn (#complete_turn, beside the stage's outgoing):
      # with objectives.tracker on, the tracker by itself, when the turn did
      # work and recorded no move (TurnStages::Objectives#track). It only
      # informs: a failure is logged.
      def track_objectives_after(turn)
        @objectives_stage.track(turn, engine: self)
      rescue StandardError => e
        Log.warn(:turn, "objectives_track_start_failed", error: e.class.name, msg: e.message)
      end

      # The stage over this Engine's side asks (built in #initialize, once
      # the host registry is). Each call takes its values: the recorder,
      # the sessions dir, the running conversation.
      def build_objectives_stage
        TurnStages::Objectives.new(side_judgments: @side_judgments, host_registry: @host_registry)
      end
    end
  end
end
