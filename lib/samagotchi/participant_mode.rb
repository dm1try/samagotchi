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

    # The mode a participant's next turn in +session+ gets, as chi web and
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
