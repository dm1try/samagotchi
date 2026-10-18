# frozen_string_literal: true

require_relative "../config"
require_relative "approval"
require_relative "parent_approvals"

module Samagotchi
  module Guardrails
    # What a parent agent may answer on a session's question: one check for
    # every asker (an approval, the step-limit Continue, a plugin's or a
    # hook's ask_user, a relayed delegate approval). The asker tags each
    # option with its effect (PendingQuestion#effects); a strategy says
    # which effects a parent may pick. `chi answer` checks it before it
    # posts; the worker's QuestionDesk checks it again, with its own config,
    # for an answer marked as a parent agent's. A convention for an honest
    # but eager parent, not a security boundary.
    #
    # Effects: answer (an untagged option), deny, spend (more time and
    # tokens: Continue), permit (one call: Allow once), permit_wide (more
    # than one call: a session, repo or rule scope). A parent never picks
    # permit_wide; on a user_only question (chi's own config, hooks or
    # guardrails) it picks only deny or answer. Text alone and a dismissal
    # always pass.
    module ParentPolicy
      ANSWER = "answer"
      DENY = "deny"
      SPEND = "spend"
      PERMIT = "permit"
      PERMIT_WIDE = "permit_wide"
      EFFECTS = [ANSWER, DENY, SPEND, PERMIT, PERMIT_WIDE].freeze
      # The effects a parent may pick with no setting at all.
      ALWAYS = [ANSWER, DENY].freeze
      # Beyond-the-strategy reasons, widest first (#refusal).
      WIDEST_FIRST = [PERMIT_WIDE, PERMIT, SPEND].freeze

      # The step-limit question (ContinueOffer).
      CONTINUE_KIND = "continue"
      CONTINUE = "Continue"
      STOP = "Stop"

      # What a parent may pick, and how a refusal names the setting that
      # refused an effect ("guardrails.parent_approvals: once").
      Strategy = Data.define(:allowed, :labels) do
        def allow?(effect) = allowed.include?(effect.to_s)

        def label(effect) = labels[effect.to_s]
      end

      module_function

      # This process's strategy (config.yml only).
      # @return [Strategy]
      def current
        legacy(parent_approvals: Config.get(ParentApprovals::KEY), parent_continue: Config.get("turn.parent_continue"))
      end

      # The strategy guardrails.parent_approvals and turn.parent_continue
      # make: answer and deny always; spend unless parent_continue is
      # false; permit with parent_approvals: once (anything else is off).
      def legacy(parent_approvals:, parent_continue: true)
        once = parent_approvals.to_s == "once"
        allowed = ALWAYS + (parent_continue == false ? [] : [SPEND]) + (once ? [PERMIT] : [])
        approvals = "#{ParentApprovals::KEY}: #{once ? "once" : "off"}"
        labels = { SPEND => "turn.parent_continue: false", PERMIT => approvals, PERMIT_WIDE => approvals }
        Strategy.new(allowed: allowed.freeze, labels: labels.freeze)
      end

      # @return [Array<String>] the effects +strategy+ lets a parent pick
      def allowed_effects(strategy) = strategy.allowed

      # Each option's effect, in option order. Tagged questions carry them;
      # an untagged one (asked by an older worker, a relayed card built
      # from an older child's question) gets them derived as before:
      # an approval's from its scopes, the step-limit question's from its
      # labels, anything else's all answer.
      # @param pending [PendingQuestion]
      # @return [Array<String>]
      def effects_of(pending)
        options = Array(pending.options)
        tags = pending.effects
        return options.each_index.map { |index| tag(tags[index]) } if tags.is_a?(Array)
        return approval_effects(pending, options) if ParentApprovals.approval?(pending)
        return options.map { |label| continue_effect(label) } if pending.kind.to_s == CONTINUE_KIND

        options.map { ANSWER }
      end

      # Whether only the user may pick a non-deny/answer option. Unset on an
      # approval (an older worker's): worked out from its facts here. A
      # relayed card: the child's flag, or this process's own look at it.
      def user_only?(pending)
        return true if pending.user_only == true
        return false unless ParentApprovals.approval?(pending)
        return false if pending.user_only == false && !pending.relay

        ParentApprovals.protected?(pending)
      end

      # Why a parent may not give this answer, or nil.
      # @param pending [PendingQuestion]
      # @param indices [Array<Integer, nil>] the selected options' places
      # @param strategy [Strategy]
      # @return [Symbol, nil] :user_only, :permit_wide, :permit or :spend
      def refusal(pending, indices, strategy:)
        effects = effects_of(pending)
        picked = Array(indices).map { |index| effect_at(effects, index) }
        return nil if picked.empty?
        return :user_only if user_only?(pending) && picked.any? { |effect| !ALWAYS.include?(effect) }

        WIDEST_FIRST.each do |effect|
          return effect.to_sym if picked.include?(effect) && !strategy.allow?(effect)
        end
        nil
      end

      # The refusal as a line for the parent: what to answer instead, or
      # tell the user. Never how to allow it (the web, chi --attach): that
      # is the user's.
      # @param reason [Symbol] what #refusal returned
      # @param typed [Boolean] the answer was typed at a ? prompt (the
      #   REPL), not given to chi answer
      def message(reason, pending:, strategy:, typed: false)
        deny = deny_label(pending)
        case reason.to_sym
        when :spend
          if pending.kind.to_s == CONTINUE_KIND
            return "a parent agent may only stop this turn here (#{strategy.label(SPEND)}): answer #{STOP} " \
                   "(--option #{STOP} --text WHY), or tell your user it waits"
          end

          "a parent agent may not pick #{tagged_labels(pending, SPEND)} here (#{strategy.label(SPEND)}): #{instead(deny, typed, "answer")}"
        when :user_only
          "this call changes chi's own config, hooks or guardrails, and only the user can allow it: #{instead(deny, typed)}"
        when :permit_wide
          # An approval whose scopes don't fit its options has no permit
          # option: its once is still what a parent may give.
          permits = tagged_labels(pending, PERMIT)
          permits = Approval::ONCE if permits.empty? && ParentApprovals.approval?(pending)
          if strategy.allow?(PERMIT) && !permits.empty?
            "only #{permits} (#{strategy.label(PERMIT_WIDE)}) can be given here: #{instead(deny, typed)}"
          else
            "#{allowing(pending)} is up to the user: #{instead(deny, typed)}"
          end
        else "#{allowing(pending)} is up to the user: #{instead(deny, typed)}"
        end
      end

      # The labels a parent may pick on +pending+ under +strategy+.
      # @return [Array<String>]
      def allowed_options(pending, strategy:)
        user_only = user_only?(pending)
        Array(pending.options).zip(effects_of(pending)).filter_map do |label, effect|
          next nil if user_only && !ALWAYS.include?(effect)

          label.to_s if strategy.allow?(effect)
        end
      end

      # The question's deny-tagged option's label, or nil.
      def deny_label(pending)
        index = effects_of(pending).index(DENY)
        index && Array(pending.options)[index].to_s
      end

      # What the parent does instead: deny with the question's own deny
      # option and tell the user, or (none) tell the user it waits.
      def instead(deny, typed, verb = "deny it")
        return "tell your user it waits" unless deny

        how = typed ? "n; WHY" : "--option #{deny} --text WHY"
        verb == "answer" ? "answer #{deny} (#{how}), or tell your user it waits" : "#{verb} (#{how}), and tell your user"
      end

      def allowing(pending)
        ParentApprovals.approval?(pending) ? "allowing a tool call" : "allowing it"
      end

      def tagged_labels(pending, effect)
        Array(pending.options).zip(effects_of(pending)).filter_map { |label, tag| label.to_s if tag == effect }.join(" or ")
      end

      # An index it can't place counts as the widest effect (fail closed).
      def effect_at(effects, index)
        return PERMIT_WIDE unless index.is_a?(Integer) && index >= 0 && index < effects.size

        effects[index]
      end

      # A tag as given; an unknown one fails closed.
      def tag(value)
        return ANSWER if value.nil?

        EFFECTS.include?(value.to_s) ? value.to_s : PERMIT_WIDE
      end

      # When the scopes fit the options: once permits, another scope
      # permits wide, the options past them deny. When they don't (missing,
      # malformed): only a last option labelled Deny denies.
      def approval_effects(pending, options)
        scopes = ParentApprovals.scopes(pending)
        if scopes
          return options.each_index.map do |index|
            next DENY if index >= scopes.size

            scopes[index] == "once" ? PERMIT : PERMIT_WIDE
          end
        end

        options.each_with_index.map do |label, index|
          index == options.size - 1 && label.to_s == Approval::DENY ? DENY : PERMIT_WIDE
        end
      end

      def continue_effect(label)
        case label.to_s
        when CONTINUE then SPEND
        when STOP then DENY
        else ANSWER
        end
      end
    end
  end
end
