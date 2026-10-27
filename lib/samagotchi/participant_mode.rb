# frozen_string_literal: true

require_relative "delivery"

module Samagotchi
  # The rules for a participant's turn: the one place that decides them.
  # - :review — a review session (its review: key, chi review): the turn
  #   only reads (Guardrails::ReviewBoundary);
  # - :pair — a working session: the turn acts with the session's tools
  #   under the owner's guardrails, asks go to the owner
  #   (Guardrails::PairBoundary keeps secrets and owner-voiced tools out).
  # No session (nil) is :review. A worker that doesn't name
  # Delivery::PAIR_FEATURE runs every participant's turn as :review, so
  # chi web and chi share ask .live, which reads the session's live worker,
  # before they say what a participant's turn may do.
  #
  # .of is the session's: what a participant invited now gets. A turn's is
  # .for_turn: :pair only for a participant whose grant was issued for it
  # (Participants::Entry#mode / Grant#mode "pair", stamped at invite when
  # the owner was shown that their turns act); a grant from before, or one
  # issued while the session's worker predated pair turns, stays :review.
  module ParticipantMode
    REVIEW = :review
    PAIR = :pair

    module_function

    # @param session [Session, nil]
    # @param features [Array<String>, nil] the features of the worker that
    #   runs the turn (WorkerSidecar#features); nil: this chi's own (the
    #   worker itself, or the one a delivery will start)
    # @return [Symbol] :review or :pair
    def of(session, features: nil)
      return REVIEW if session.nil? || !session.respond_to?(:review?) || session.review?
      return REVIEW if features && !features.include?(Delivery::PAIR_FEATURE)

      PAIR
    end

    # The mode a turn of the participant +entry+ (a Participants::Entry or a
    # Web::Grants::Grant; nil: unknown) runs under in +session+.
    # @return [Symbol]
    def for_turn(session, entry, features: nil)
      return REVIEW unless of(session, features: features) == PAIR
      return REVIEW unless entry.respond_to?(:mode) && entry.mode.to_s == PAIR.to_s

      PAIR
    end

    # .for_turn as chi web sees it, by the live worker's features (.live).
    def live_for(session, entry, state_dir: nil)
      for_turn(session, entry, features: live_features(session, state_dir))
    end

    # The mode a participant invited to +session+ now gets, as chi web and
    # chi share see it: by the session's live worker's features (an older
    # worker runs it as :review), else by this chi's (no live worker: the
    # one a delivery starts is this chi's).
    # @param state_dir [String, nil] the sessions' state dir (nil: the default)
    # @return [Symbol]
    def live(session, state_dir: nil)
      of(session, features: live_features(session, state_dir))
    end

    # Whether +session+ is a working session whose live worker still runs a
    # participant's turn as a review (it predates Delivery::PAIR_FEATURE).
    def older_worker?(session, state_dir: nil)
      of(session) == PAIR && live(session, state_dir: state_dir) == REVIEW
    end

    # The live worker's features, nil without a live worker (or when it
    # can't be read).
    def live_features(session, state_dir)
      return nil if session.nil? || !session.respond_to?(:id) || session.id.to_s.empty?

      require_relative "session"
      require_relative "worker_link"
      dir = Session.session_dir(session.id, state_dir: state_dir || Session.default_state_dir)
      link = WorkerLink.resolve(dir, unlink: false)
      link.live? ? link.features : nil
    rescue StandardError
      nil
    end
  end
end
