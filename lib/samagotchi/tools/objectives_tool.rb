# frozen_string_literal: true

require_relative "../tool_response"

module Samagotchi
  # Read at a call only: the builtins' file list loads this, Session not with it.
  autoload :Objectives, File.expand_path("../objectives", __dir__)

  module Tools
    # The objectives tool's one action: a move, what the model did or found for
    # an objective. Information only: it never changes a status or the list
    # (the user does, /objectives), and nothing is written here: the call in
    # history is the record, which Objectives.build reads back. So this only
    # checks the call and says what it did. See docs/internals/objectives.md.
    class ObjectivesTool
      NAME = "objectives"
      MOVE = "move"
      RECORDED = "Recorded a move on %s."
      EDITED_BY_USER = "The user edits the list with /objectives."
      NONE = "There are no objectives here, so nothing was recorded. #{EDITED_BY_USER}".freeze

      def self.name = NAME

      # Whether +output+, a saved run, is this tool's answer that it recorded a
      # move on +id+ (Objectives.moves_in). Positive: a run that recorded
      # nothing (no list, a refusal, a denial, an interrupt) has no such answer.
      def self.recorded?(output, id)
        output.to_s.sub(ToolResponse::LEAD, "").start_with?(RECORDED % id)
      end

      # @param call [Hash] the internal call (BuiltinCalls: action:, id:,
      #   note:, evidence:)
      # @param peers [#objectives, nil] the session's list
      # @return [String] the tool result
      def self.call(call, peers:)
        action = call[:action].to_s.strip.downcase
        unless action.empty? || action == MOVE
          return "Error: this tool only records a move (action: move); it edits nothing. #{EDITED_BY_USER}"
        end

        list = peers&.objectives
        return NONE if list.nil? || list.empty?

        id = Objectives.move_id(call)
        refusal(list, id, call) || "#{RECORDED % id} The list is unchanged: this tool doesn't edit it. #{EDITED_BY_USER}"
      end

      def self.refusal(list, id, call)
        item = list.find(id)
        return "Error: no objective #{id} (this session's: #{list.items.map(&:id).join(", ")}). Nothing was recorded." unless item
        return "Error: #{id} was dropped, so nothing was recorded." if item.status == Objectives::DROPPED

        "Error: a move needs a note: what moved, in a line." if Objectives.clean(call[:note]).empty?
      end
      private_class_method :refusal
    end
  end
end
