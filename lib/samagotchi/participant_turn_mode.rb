# frozen_string_literal: true

module Samagotchi
  # Whether a participant's turn runs here, and why not: the one decision
  # the worker (Worker#participant_refusal, before the turn starts and
  # before each of its generations) and the guardrails
  # (GuardrailWiring#participant_turn_mode, the turn's mode) both take.
  #   :pair        — it runs, under the owner's guardrails (PairBoundary);
  #   :revoked     — no invite at +now+: none, revoked, expired, or anything
  #                  that isn't a participants.json entry;
  #   :outdated    — an older chi's read-only invite (no PAIR_MODE), or a
  #                  participant's Verify fresh child saved for a read-only
  #                  turn: this chi runs no read-only turn;
  #   :not_invited — invited, but not to this: no session, or the owner's
  #                  own Verify fresh child (its parent's participants are
  #                  the parent's; only a participant's own child runs
  #                  their turns).
  # Fail closed: only :pair runs. See docs/guardrails.md ("A participant's
  # turn without a current invite").
  module ParticipantTurnMode
    # The mode every invite this chi issues is stamped with (Grants'
    # grants, participants.json entries, a participant's Verify fresh
    # child) and a pair turn's opening message keeps (participant_mode).
    # The web's participant_names.js PAIR reads the same stamp.
    PAIR_MODE = "pair"
    MODES = %i[pair outdated revoked not_invited].freeze

    module_function

    # @param entry [Participants::Entry, nil] the participant's entry
    #   (participants.json of Session#participants_source_id)
    # @param session [Session, nil] the session the turn would run in
    # @param now [Time]
    # @return [Symbol] one of MODES
    def of(entry:, session:, now:)
      return :revoked unless entry.respond_to?(:mode) && entry.respond_to?(:current?) && entry.current?(now)
      return :outdated unless invite_mode?(entry.mode)
      return :not_invited if session.nil?

      fresh = session.respond_to?(:verify_fresh) ? session.verify_fresh : nil
      return :pair unless fresh
      return :not_invited unless fresh.participant?

      fresh.pair? ? :pair : :outdated
    end

    # Whether +mode+ (a grant's, an entry's) is this chi's invite mode.
    def invite_mode?(mode) = mode.to_s == PAIR_MODE
  end
end
