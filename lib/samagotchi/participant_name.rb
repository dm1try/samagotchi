# frozen_string_literal: true

module Samagotchi
  # A participant's name as chi shows it to anyone, the model included: one
  # line of at most MAX characters with no brackets (nor Unicode line
  # breaks, nor full-width square brackets), so a name can't close or forge
  # the review-contribution header (Steer.review_header). The grants store
  # cleans a name at issue (Web::Grants.clean_name); the header cleans it
  # again, whatever a session file or a sidecar holds.
  module ParticipantName
    MAX = 64
    UNSAFE = /[[:cntrl:]\p{Zl}\p{Zp}\[\]［］【】〔〕]/

    module_function

    # @return [String] "" when nothing is left
    def clean(name)
      name.to_s.gsub(UNSAFE, " ").squeeze(" ").strip[0, MAX].to_s.strip
    end
  end
end
