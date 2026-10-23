# frozen_string_literal: true

module Samagotchi
  # A review session's own field (chi review, the web's Start review): the
  # files under review, project-relative (the session's work tree top),
  # and, for a review fork (chi review --from), the session it started from.
  # A session without one isn't a review session; its file has no "review"
  # key at all (Session::OPTIONAL_FIELDS), so other session files stay as
  # they were. Kept by continues; never by forks or delegate children.
  # See docs/sessions.md (Review sessions).
  SessionReview = Data.define(:subjects, :from) do
    def initialize(subjects: [], from: nil)
      super(subjects: Array(subjects).map(&:to_s).reject(&:empty?).uniq.freeze, from: from&.to_s)
    end

    # A SessionReview from the session file's form ({"subjects" => […],
    # "from" => id}), a SessionReview, or nil (nil for nil or a non-hash).
    def self.of(value)
      case value
      when SessionReview then value
      when Hash then new(subjects: value["subjects"] || value[:subjects], from: value["from"] || value[:from])
      end
    end

    # The session file's form: "from" only when there is one.
    def to_file = { "subjects" => subjects, "from" => from }.compact
  end
end
