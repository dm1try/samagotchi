# frozen_string_literal: true

require_relative "../guardrails/verdict"

module Samagotchi
  module Testing
    # One deny! or ask! a voter cast, kept or not.
    Vote = Data.define(:decision, :reason, :options)

    # A real Guardrails::Verdict that also records every deny! and ask!
    # (#votes), for tests that count votes or check their keywords
    # (advice:, rule:), even the ones a stricter earlier vote ignored.
    class Verdict < Guardrails::Verdict
      # @return [Array<Vote>]
      def votes = (@votes ||= [])

      def deny!(reason, **options)
        votes << Vote.new(decision: :deny, reason: reason, options: options)
        super
      end

      def ask!(reason, **options)
        votes << Vote.new(decision: :ask, reason: reason, options: options)
        super
      end
    end
  end
end
