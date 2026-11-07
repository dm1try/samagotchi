# frozen_string_literal: true

module Samagotchi
  class Engine
    # The attached-context candidate judge (TurnStages::ContextJudge,
    # forwarded): prepare_turn starts its pass, run_turn's ensure shows the
    # cards it held, and a plugin's late candidate asks it. Reads
    # @context_judge, @side_judgments, @host_registry, @session.
    module ContextJudgePart
      private

      # The judge's stage (TurnStages::ContextJudge).
      attr_reader :context_judge

      # A late proposal no owner prompt mentions (Plugin::Host
      # #candidate_proposed): TurnStages::ContextJudge#late_candidates.
      def judge_late_candidates = @context_judge.late_candidates

      # The stage over this Engine's side asks and its session (built in
      # #build_tools_and_plugins, before the plugins load: one may propose a
      # candidate as it loads).
      def build_context_judge
        TurnStages::ContextJudge.new(
          side_judgments: @side_judgments, host_registry: @host_registry, state_dir: -> { session_state_dir },
          recording: ->(client, judgment, session, mode:) { system_one_recording(client, judgment, session, mode: mode) },
          session: -> { @session }, messages: -> { plugin_messages }, turn_running: -> { turn_running? },
          show_card: ->(**card) { show_card(**card) }
        )
      end
    end
  end
end
