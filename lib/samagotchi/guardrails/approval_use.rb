# frozen_string_literal: true

require_relative "approvals"
require_relative "../turn_origin"

module Samagotchi
  module Guardrails
    # Which stored approvals an ask may use: the one place that says so
    # (Gate#settle_ask asks it before it looks in the store).
    #   all     — any stored entry: session, repo or rule (an owner's turn);
    #   session — only this session's own "Allow for this session" entries:
    #             a participant's turn (the owner's repo or rule approvals
    #             are the owner's, for the owner's turns), and an ask of a
    #             rule in SESSION_ONLY_RULES (a delegate child's boundary: a
    #             repo entry would hold in every worktree, for every child);
    #   none    — no stored entry: a fresh ask (Verdict#fresh_ask, the pair
    #             boundary's own asks).
    # A later policy (say a softer one for participants) is one more
    # POLICIES key and one branch in .policy.
    module ApprovalUse
      POLICIES = { all: Approvals::STORED_SCOPES, session: %w[session].freeze, none: [].freeze }.freeze
      # Rules a stored answer allows only for its session: their asks offer
      # once/session, and a repo entry for the same call (from another
      # rule) would hold in every worktree, for every child. The id is
      # ChildBoundary::RULE (spelled here so the store needs no shell lexer;
      # approval_use_spec checks they agree).
      SESSION_ONLY_RULES = %w[child-boundary].freeze

      module_function

      # Fail closed: only a turn known to be the owner's gets :all. A call
      # with no TurnContext (nil, or anything that can't say whose turn it
      # is) gets :session, and so does one whose judged context names a
      # participant's author (verdict.context's origin), whatever the turn
      # says: a wider approval is the owner's, and an unknown caller is no
      # owner.
      # @param verdict [Verdict] the ask
      # @param turn [TurnContext, nil] the call's turn
      # @return [Symbol] a POLICIES key
      def policy(verdict, turn)
        return :none if verdict.fresh_ask?
        return :session unless turn.respond_to?(:participant?)
        return :session if turn.participant? || participant_call?(verdict) || SESSION_ONLY_RULES.include?(verdict.rule.to_s)

        :all
      end

      # @return [Array<String>] the stored scopes +verdict+ may match (empty: none)
      def scopes(verdict, turn) = POLICIES.fetch(policy(verdict, turn))

      # Whether the call's judged context (Gate#evaluate's) names a
      # participant's author.
      def participant_call?(verdict)
        origin = verdict.context.respond_to?(:origin) ? verdict.context.origin : nil
        !!TurnOrigin.from(origin)&.participant?
      end
    end
  end
end
