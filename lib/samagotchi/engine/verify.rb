# frozen_string_literal: true

module Samagotchi
  class Engine
    # Verify and Revise anchors (TurnStages::VerifyAnchors): #begin_turn
    # checks a Verify turn's claim, #end_turn's event step stamps the opening
    # and records the verdict. Reads @verify_anchors.
    module VerifyPart
      private

      # The anchors' stage (TurnStages::VerifyAnchors).
      attr_reader :verify_anchors

      def build_verify_anchors = TurnStages::VerifyAnchors.new(state_dir: -> { session_state_dir })
    end
  end
end
