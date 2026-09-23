# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # The gate's verdict for one tool call. Voters (hooks now, rules later)
    # call #deny! or #ask!; the strictest vote wins (deny > ask > allow) and
    # a vote never relaxes it, so a deny is sticky. Of two equal votes the
    # first one stays.
    class Verdict
      STRICTNESS = { allow: 0, ask: 1, deny: 2 }.freeze
      SCOPES = %w[once session repo rule].freeze
      DO_NOT_RETRY = "Do not retry it or reach the same result another way; ask the user how to proceed."

      attr_reader :decision, :reason, :rule, :source, :scopes, :decided_by
      # The call to dispatch; a hook may have replaced the original one.
      attr_accessor :call

      def initialize(call:)
        @call = call
        @decision = :allow
        @reason = nil
        @rule = nil
        @source = nil
        @scopes = SCOPES
        @decided_by = nil
        @legacy = false
        @note = nil
        @voter = nil
      end

      # @param rule [String, nil] the rule id, when a rule decided
      # @param source [String, nil] where the rule came from ("config", "bundle x")
      def deny!(reason, rule: nil, source: nil, decided_by: "hook")
        vote(:deny, reason, rule: rule, source: source, decided_by: decided_by)
        self
      end

      # @param scopes [Array<String>, nil] which approval scopes the user may
      #   pick (default all of SCOPES)
      def ask!(reason, scopes: nil, rule: nil, source: nil, decided_by: "hook")
        return self unless vote(:ask, reason, rule: rule, source: source, decided_by: decided_by)

        picked = Array(scopes).map(&:to_s) & SCOPES
        @scopes = picked.empty? ? SCOPES : picked
        self
      end

      # A before_tool_call hook set the old event[:blocked] flag. Its model
      # text stays "blocked by guardrail: <reason>".
      def legacy_deny!(reason)
        @legacy = true if vote(:deny, reason, decided_by: "hook")
        self
      end

      # The user (or the lack of one) settled an ask.
      # @param note [String, nil] for a deny, what the model is told about
      #   the user ("The user declined.", "No one to approve it.")
      def settle!(decision, decided_by: "user", note: nil)
        @decision = decision
        @decided_by = decided_by
        @note = note
        self
      end

      def allow? = @decision == :allow
      def ask? = @decision == :ask
      def deny? = @decision == :deny
      def legacy? = @legacy

      # What the model gets for a deny (after the "[tool] Error: " prefix):
      # who decided, why, and not to route around it.
      def deny_text
        reason = @reason.to_s.strip
        reason += "." unless reason.empty? || reason.match?(/[.!?]\z/)
        [
          "denied by guardrail (#{decider}):", reason, @note || "The user was not asked.", DO_NOT_RETRY
        ].reject(&:empty?).join(" ")
      end

      # For the activity entry.
      def to_activity
        { rule: @rule, verdict: @decision.to_s, decided_by: @decided_by }.compact
      end

      private

      def decider
        return [("rule #{@rule}" if @rule), @source].compact.join(", ") if @rule || @source

        @voter || "hook"
      end

      def vote(decision, reason, decided_by:, rule: nil, source: nil)
        return false unless STRICTNESS.fetch(decision) > STRICTNESS.fetch(@decision)

        @decision = decision
        @reason = reason.to_s.strip
        @rule = rule&.to_s
        @source = source&.to_s
        @decided_by = decided_by
        @voter = decided_by
        @legacy = false
        true
      end
    end
  end
end
