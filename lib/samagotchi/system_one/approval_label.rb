# frozen_string_literal: true

require_relative "../question_answer"
require_relative "approval_question"
require_relative "runs"

module Samagotchi
  module SystemOne
    # What an answer to an approval says about the ask, for the judgments log
    # (its value) and the saved run (all of it). The scope they took, a
    # denial, or none for an ask that was cancelled, which is not an answer.
    # A parent agent's answer is not the user's: its allow labels nothing, and
    # its deny is a weak label only where the parent could have allowed — a
    # parent that was not allowed to permit says nothing about what the user
    # would have done (docs/guardrails.md, "System 1").
    module ApprovalLabel
      Label = Data.define(:value, :by, :strength)

      # `/guardrails wrong`, the web's "should have asked".
      WRONG = Label.new(value: "should_have_asked", by: "user", strength: "strong")
      NONE = Label.new(value: "none", by: "none", strength: nil)

      module_function

      # @param answer [QuestionAnswer, Object] anything else: the ask was cancelled
      # @param scopes [Array<String>] the scopes the ask offered
      # @param parent_may_permit [#call] whether the session's parent may
      #   allow this ask (read only for a parent's deny)
      # @return [Label, nil] nil: this answer is no label
      def of(answer, scopes:, parent_may_permit:)
        return NONE unless answer.is_a?(Samagotchi::QuestionAnswer)

        index = answer.selected_indices.first
        allowed = !index.nil? && index < scopes.size
        if answer.parent_agent?
          return nil if allowed || !parent_may_permit.call

          return Label.new(value: "deny", by: "parent", strength: "weak")
        end

        value = if allowed
                  scopes[index] == "once" ? "allow_once" : "allow_wide"
                else
                  "deny"
                end
        Label.new(value: value, by: "user", strength: "strong")
      end

      # On the saved run +id+ names; an id from before runs has none.
      # @param runs [Runs, nil]
      def save(runs, id, label)
        runs&.label(id, label.value, by: label.by, strength: label.strength, question: ApprovalQuestion::ID)
      end
    end
  end
end
