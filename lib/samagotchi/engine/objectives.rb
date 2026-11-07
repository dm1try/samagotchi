# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session's objectives (TurnStages::Objectives, forwarded): the view
    # announced when it changed, the model's proposals kept as cards until
    # the turn is over, System 1's audit of them (ObjectivesAudit); and
    # Check this's side request. Reads @objectives_stage, @side_judgments,
    # @host_registry, @session.
    module ObjectivesPart
      # The session's objectives as the page draws them, when that differs
      # from the last announced (TurnStages::Objectives#announce).
      def announce_objectives(session = @session) = @objectives_stage.announce(session)

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
      # is over (TurnStages::Objectives#propose).
      # @return [Boolean] false past Objectives::PROPOSALS_PER_TURN
      def propose_objective(proposal) = @objectives_stage.propose(proposal)

      private

      # The objectives' stage (TurnStages::Objectives).
      attr_reader :objectives_stage

      # The stage over this Engine's side asks and its event lock (built in
      # #initialize, once the host registry is).
      def build_objectives_stage
        TurnStages::Objectives.new(
          side_judgments: @side_judgments, host_registry: @host_registry, state_dir: -> { session_state_dir },
          recording: ->(client, judgment, session, mode:) { system_one_recording(client, judgment, session, mode: mode) },
          runs: -> { system_one_runs }, synchronize: ->(&block) { synchronize_events(&block) },
          announce: ->(event) { announce(event) }, running: -> { live_conversation },
          show_card: ->(**card) { show_card(**card) }
        )
      end
    end
  end
end
