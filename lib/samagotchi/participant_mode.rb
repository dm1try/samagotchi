# frozen_string_literal: true

module Samagotchi
  # The rules for a participant's turn. P0 keeps every participant in review
  # mode; this is the single resolver for the later mode split.
  module ParticipantMode
    module_function

    def of(_session) = :review
  end
end
