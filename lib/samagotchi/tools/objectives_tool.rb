# frozen_string_literal: true

require_relative "../tool_response"
require_relative "../tool_names"

module Samagotchi
  # Read at a call only: the builtins' file list loads this, Session not with it.
  autoload :Objectives, File.expand_path("../objectives", __dir__)

  module Tools
    # The objectives tool's two actions. A move: what the model did or found for
    # an objective. Information only: it never changes a status or the list
    # (the user does, /objectives), and nothing is written here: the call in
    # history is the record, which Objectives.build reads back. A proposal: a
    # change to the list the user applies from a card with one tap, the card's
    # action being the /objectives line; the model never changes the list by
    # itself. See docs/internals/objectives.md.
    class ObjectivesTool
      NAME = ToolNames::ObjectivesTool::NAME
      MOVE = "move"
      PROPOSE = ToolNames::ObjectivesTool::PROPOSE
      PROPOSED = "Proposed %s. The list is unchanged: the user sees a card and applies it or not."
      RECORDED = "Recorded a move on %s."
      EDITED_BY_USER = "The user edits the list with /objectives."
      NONE = "There are no objectives here, so nothing was recorded. #{EDITED_BY_USER}".freeze
      # A move's state: where the objective stands in the agent's view. DONE is
      # its claim, never a status change (the user marks done).
      PROGRESS = "progress"
      BLOCKED = ToolNames::ObjectivesTool::BLOCKED
      DONE = ToolNames::ObjectivesTool::DONE
      STATES = [PROGRESS, BLOCKED, DONE].freeze

      def self.name = NAME

      # Whether +output+, a saved run, is this tool's answer that it recorded a
      # move on +id+ (Objectives.moves_in). Positive: a run that recorded
      # nothing (no list, a refusal, a denial, an interrupt) has no such answer.
      def self.recorded?(output, id)
        output.to_s.sub(ToolResponse::LEAD, "").start_with?(RECORDED % id)
      end

      # A call's state as a move takes it: stripped and downcased, PROGRESS
      # when it names none; nil for one that isn't a state.
      def self.state_of(call)
        state = call[:state].to_s.strip.downcase
        return PROGRESS if state.empty?

        STATES.include?(state) ? state : nil
      end

      # @param call [Hash] the internal call (BuiltinCalls: action:, id:,
      #   note:, evidence:, state:)
      # @param peers [#objectives, nil] the session's list
      # @return [String] the tool result
      def self.call(call, peers:)
        action = call[:action].to_s.strip.downcase
        unless action.empty? || [MOVE, PROPOSE].include?(action)
          return "Error: this tool records a move (action: move) or proposes a change (action: propose); it edits nothing. #{EDITED_BY_USER}"
        end

        list = peers&.objectives
        return NONE if list.nil? || list.empty?
        return propose(list, call, peers) if action == PROPOSE

        id = Objectives.move_id(call)
        refusal(list, id, call) || "#{RECORDED % id} The list is unchanged: this tool doesn't edit it. #{EDITED_BY_USER}"
      end

      def self.propose(list, call, peers)
        proposal = Objectives::Proposal.against(list, change: call[:change].to_s.strip.downcase, id: Objectives.move_id(call),
                                                      text: Objectives.clean(call[:text]), note: Objectives.clean(call[:note]))
        refused = proposal.refusal(list)
        return "Error: #{refused}. Nothing was proposed." if refused

        return "Error: at most #{Objectives::PROPOSALS_PER_TURN} proposals a turn. Nothing more was proposed." unless peers.propose_objective(proposal)

        format(PROPOSED, proposal.line.delete_prefix("/objectives "))
      end
      private_class_method :propose

      def self.refusal(list, id, call)
        item = list.find(id)
        return "Error: #{Objectives.unknown(id, list)}. Nothing was recorded." unless item
        return "Error: #{Objectives.dropped(id)}. Nothing was recorded." if item.status == Objectives::DROPPED

        return "Error: a move needs a note: what moved, in a line." if Objectives.clean(call[:note]).empty?

        "Error: a move's state must be #{STATES[0..-2].join(", ")} or #{STATES.last}. Nothing was recorded." unless state_of(call)
      end
      private_class_method :refusal
    end
  end
end
