# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # The gate's verdict for one tool call. Voters (hooks now, rules later)
    # call #deny! or #ask!; the strictest vote wins (deny > ask > allow) and
    # a vote never relaxes it, so a deny is sticky. Of two equal votes the
    # first one stays, except that a protected rule's ask (PROTECTED_RULES)
    # takes over an unprotected ask: its rule id is what a parent's answer
    # and a stored approval are checked against, and the offered scopes
    # narrow to both asks' common ones.
    class Verdict
      STRICTNESS = { allow: 0, ask: 1, deny: 2 }.freeze
      # Rules that ask about chi's own config and hooks: the core
      # ProtectedPaths asks and the guardrails bundle's shell rule; and a
      # command source for attached context (it runs later, ungated); chi
      # broadcast, which is the user's; the bundle's asks before a memory
      # that reaches the system prompt, or a model overlay, is written (a
      # parent model would be writing a model's prompt); and the bundle's
      # asks before answering chi's questions around chi answer (a parent
      # allowing one would answer a grandchild's question as the user).
      # A parent agent may never allow them (ParentApprovals.protected?,
      # ParentPolicy's user_only); System 1 may, only if the user lists the
      # rule by name in guardrails.system_one.rules, and never for the
      # chi-answer/chi-broadcast ones (SystemOne::SelfProtect::NEVER_AUTO).
      PROTECTED_RULES = %w[chi-config chi-hooks shell-touches-chi chi-context-cmd chi-broadcast prompt-memory-write
                           model-overlay-write chi-answer-piped chi-answer-http].freeze
      SCOPES = %w[once session repo rule].freeze
      DO_NOT_RETRY = "Do not retry it or reach the same result another way; ask the user how to proceed."

      attr_reader :decision, :reason, :rule, :source, :scopes, :decided_by
      # The call to dispatch; a hook may have replaced the original one.
      attr_accessor :call
      # The Context and the final call's Targets (set by the Gate).
      attr_accessor :context, :targets
      # The scope the user allowed an ask for ("once", "session", …).
      attr_accessor :scope
      # System 1's judgment that decided an ask, when it did: {id:, p:}.
      attr_accessor :judgment

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
        @advice = nil
      end

      # @param rule [String, nil] the rule id, when a rule decided
      # @param source [String, nil] where the rule came from ("config", "bundle x")
      # @param advice [String, nil] what the model should do instead, in
      #   place of the fixed "Do not retry it…" tail (a hook that rejects a
      #   call so the model retries it corrected)
      def deny!(reason, rule: nil, source: nil, decided_by: "hook", advice: nil)
        @advice = advice.to_s.strip.empty? ? nil : advice.to_s.strip if vote(:deny, reason, rule: rule, source: source, decided_by: decided_by)
        self
      end

      # @param scopes [Array<String>, nil] which approval scopes the user may
      #   pick (default all of SCOPES)
      def ask!(reason, scopes: nil, rule: nil, source: nil, decided_by: "hook")
        earlier = ask? ? @scopes : nil
        return self unless vote(:ask, reason, rule: rule, source: source, decided_by: decided_by)

        picked = Array(scopes).map(&:to_s) & SCOPES
        picked = SCOPES if picked.empty?
        picked &= earlier if earlier
        @scopes = picked.empty? ? %w[once] : picked
        self
      end

      def self.protected_rule?(rule) = PROTECTED_RULES.include?(rule.to_s)

      # A before_tool_call hook set the old event[:blocked] flag. Its model
      # text stays "blocked by guardrail: <reason>".
      def legacy_deny!(reason)
        @legacy = true if vote(:deny, reason, decided_by: "hook")
        self
      end

      # Back to allow (guardrails disabled: a hook's ask doesn't count).
      def drop_ask!
        return self unless ask?

        @decision = :allow
        @reason = @rule = @source = @decided_by = @voter = @advice = nil
        @scopes = SCOPES
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
      # who decided, why, and not to route around it (or the voter's own
      # advice). A user's deny leads with the user's answer, so it doesn't
      # read as the rule refusing.
      def deny_text
        reason = @reason.to_s.strip
        reason += "." unless reason.empty? || reason.match?(/[.!?]\z/)
        parts = if @decided_by == "user" && @note
                  [@note, "It needed approval (#{decider}):", reason]
                else
                  ["denied by guardrail (#{decider}):", reason, @note || "The user was not asked."]
                end
        (parts << (@advice || DO_NOT_RETRY)).reject(&:empty?).join(" ")
      end

      # For the activity entry; an allowed ask notes how ("approved (repo)",
      # "approved earlier (session)"), one System 1 answered notes that and
      # carries the judgment (docs/guardrails.md, "System 1").
      def to_activity
        return system_one_activity if @decided_by == "system one"

        note = if allow? && @scope
                 "approved#{" earlier" if @decided_by == "approval"} (#{@scope})"
               end
        { rule: @rule, verdict: @decision.to_s, decided_by: @decided_by, scope: @scope, note: note }.compact
      end

      private

      # The auto-allow's activity: who decided, for how long, and the
      # judgment behind it (the p and the judgment's id), so a UI can show
      # why the call was never asked about.
      def system_one_activity
        facts = @judgment || {}
        p = facts[:p]
        activity = { rule: @rule, verdict: @decision.to_s, decided_by: @decided_by, scope: @scope,
                     note: p ? "auto-allowed by System 1 (p=#{format("%.2f", p.to_f)})" : "auto-allowed by System 1" }
        activity[:judgment_id] = facts[:id] if facts[:id]
        activity[:p] = p if p
        activity.compact
      end

      def decider
        return [("rule #{@rule}" if @rule), @source].compact.join(", ") if @rule || @source

        @voter || "hook"
      end

      def vote(decision, reason, decided_by:, rule: nil, source: nil)
        return false unless STRICTNESS.fetch(decision) > STRICTNESS.fetch(@decision) || takes_over?(decision, rule)

        @decision = decision
        @reason = reason.to_s.strip
        @rule = rule&.to_s
        @source = source&.to_s
        @decided_by = decided_by
        @voter = decided_by
        @legacy = false
        true
      end

      # A protected rule's ask over an unprotected one.
      def takes_over?(decision, rule)
        decision == :ask && ask? && Verdict.protected_rule?(rule) && !Verdict.protected_rule?(@rule)
      end
    end
  end
end
