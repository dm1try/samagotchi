# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # The outcome of the gate for one tool call: allow or deny (with the
    # reason), and the call to dispatch (a hook may have replaced it).
    class Verdict
      attr_reader :decision, :reason, :call

      def initialize(decision, call:, reason: nil)
        @decision = decision
        @call = call
        @reason = reason
      end

      def deny? = @decision == :deny
      def allow? = @decision == :allow
    end
  end
end
