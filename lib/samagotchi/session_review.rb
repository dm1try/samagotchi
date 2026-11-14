# frozen_string_literal: true

module Samagotchi
  # Legacy metadata on a session started by an older chi review command:
  # the project-relative files and, for a fork, the session it came from.
  # Current chi keeps the "review" key as written for compatibility, but
  # does not use it to change session behavior. Continues keep it; forks
  # and delegate children do not. See docs/sessions.md (Older review sessions).
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
