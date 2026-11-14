# frozen_string_literal: true

require_relative "../steer"

module Samagotchi
  module Guardrails
    # The participant boundary's seat (GuardrailWiring#checks) for a
    # participant's turn this chi doesn't run under the owner's rules: no
    # current invite (an older chi's read-only one, no grant at all), a
    # Verify fresh child saved for a read-only turn, or no session. The
    # worker refuses such a turn before it starts (Worker#participant_refusal);
    # this is the fail-closed fallback should one start anyway: every call is
    # denied, nobody is asked. A no-op for the owner's turns.
    class ParticipantRefusal
      RULE = "participant-refused"
      SOURCE = "core"
      REASON = "this participant's turn runs no tools: their invite is from an older chi or has ended"
      ADVICE = "Answer in text only; the session's owner can invite them again."

      # @param author [#call] → String, nil: the running turn's author
      def initialize(author:)
        @author = author
      end

      # Vote on +verdict+.
      def check(verdict)
        return verdict unless Steer.participant_author?(@author.call)

        verdict.deny!(REASON, rule: RULE, source: SOURCE, decided_by: "core", advice: ADVICE)
      end
    end
  end
end
