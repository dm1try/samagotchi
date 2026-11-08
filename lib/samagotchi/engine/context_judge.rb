# frozen_string_literal: true

module Samagotchi
  class Engine
    # The attached-context candidate judge (TurnStages::ContextJudge,
    # forwarded): prepare_turn starts its pass, run_turn's ensure shows the
    # cards it held, and a plugin's late candidate asks it. Reads
    # @context_judge, @side_judgments, @host_registry, @turn_state, @session.
    module ContextJudgePart
      private

      # The judge's stage (TurnStages::ContextJudge).
      attr_reader :context_judge

      # A late proposal no owner prompt mentions (Plugin::Host
      # #candidate_proposed, maybe while the plugins load, before a session
      # or the event log is there): TurnStages::ContextJudge#late_candidates
      # on the session the Engine is on (none, or a review session: nothing,
      # before anything else is read), the owner's prompts so far, the
      # recorder and the sessions dir, all read now on the caller's thread.
      def judge_late_candidates
        session = @session
        return if session.nil? || session.review?

        @context_judge.late_candidates(session, messages: plugin_messages, recorder: system_one_recorder,
                                                state_dir: session_state_dir)
      end

      # The stage over this Engine's side asks (built in
      # #build_tools_and_plugins, before the plugins load: one may propose a
      # candidate as it loads). Its two callables are the asks thread's late
      # reads: the session the Engine is on and where a card goes, both as
      # an answer comes.
      def build_context_judge
        TurnStages::ContextJudge.new(side_judgments: @side_judgments, host_registry: @host_registry, turn_state: @turn_state,
                                     show_card: ->(**card) { show_card(**card) }, current_session: -> { @session })
      end
    end
  end
end
