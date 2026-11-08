# frozen_string_literal: true

require_relative "steer"
require_relative "bridge/card_places"

module Samagotchi
  # Where a saved recap sits among the turns a page draws: after the last
  # turn opening it covers (Steer.turn_opening?, the rule its turns_since
  # count goes by). Its stamp is that opening's id, as a card's is
  # (Bridge::CardPlaces.stamp: a prompt's turn_id, a wake note's, a
  # /continue no reason line's opening_id), so the page finds the bubble by
  # id, not by counting back (a rollback or a check-in could make the count
  # land a turn off). Read at read time from recap.json's `covered`: the file
  # is unchanged, an old one gets a stamp too. Pure.
  module RecapPlace
    module_function

    # @param messages [Array<Hash>] the session's messages (symbol or string keys)
    # @param covered [Integer] how many of them the recap covers
    # @return [String, nil] the id of the last opening in the covered
    #   messages; nil for none, or one with no id (a line an older chi wrote)
    def opening_id(messages, covered)
      opening = Array(messages).first([covered.to_i, 0].max).reverse_each.find { |message| Steer.turn_opening?(message) }
      opening && Bridge::CardPlaces.stamp(opening)
    end
  end
end
