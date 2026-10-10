# frozen_string_literal: true

module Samagotchi
  # How a session's last turn ended (Session#last_turn), saved as
  # session.json's "last_turn" and sent in the web's session summary.
  # Engine#record_last_turn writes it at every turn's end, ContinueOffer
  # when a Stop answered the step-limit question (no turn ran).
  #
  # outcome: "completed", "failed", "canceled" or "not_continued";
  # ended_at: iso8601; seconds: Float; origin: "client", "reminder",
  # "delegate", "delegate_report" (a turn a parent ran for its delegate
  # children's reports) or "context" (one an attached context source's
  # change started); exhausted/limit: the turn ran out of iterations at
  # limit. The rest are its stop facts (LastTurn::STOP_FACTS), only what is
  # known. A field may be nil (unset; left out of the file).
  LastTurn = Data.define(:outcome, :ended_at, :seconds, :origin, :exhausted, :limit,
                         :error_kind, :retryable, :kept_steps, :cancel_reason, :stopped_by) do
    def initialize(**fields)
      super(**members.to_h { |m| [m, nil] }, **fields)
    end

    # A saved record (string keys; symbol keys read too, a key we don't
    # know dropped), a LastTurn as it is; nil for anything else.
    # @return [LastTurn, nil]
    def self.from_file(raw)
      return raw if raw.is_a?(LastTurn)
      return nil unless raw.is_a?(Hash)

      new(**members.to_h { |m| [m, raw.key?(m.to_s) ? raw[m.to_s] : raw[m]] })
    end

    # The session file's record: string keys, in member order, unset
    # fields left out.
    # @return [Hash{String => Object}]
    def to_file = to_h.compact.transform_keys(&:to_s)

    # The stop facts this turn has (LastTurn::STOP_FACTS), symbol keys.
    # @return [Hash{Symbol => Object}]
    def stop_facts = to_h.slice(*self.class::STOP_FACTS).compact
  end

  # Why a turn stopped, for a parent agent's wait (ReplyWait::Result takes
  # them by these names): a failed turn's provider error kind, whether a
  # retry may help and whether its work stayed (kept_steps: a parent must
  # not send the task again); a canceled one's reason and the hook that
  # stopped it.
  LastTurn::STOP_FACTS = %i[error_kind retryable kept_steps cancel_reason stopped_by].freeze
end
