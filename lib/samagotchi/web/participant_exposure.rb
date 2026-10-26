# frozen_string_literal: true

module Samagotchi
  module Web
    # What a participant may learn of their review's usage, by their grant's
    # exposure level (Grants::Grant#exposure; the review-composer plan's D3):
    # the policy that maps a level to the usage fields the review route
    # gives them (ParticipantReview#review_usage). One level today:
    #
    # - +own+ (every grant's): their own spend and cap, their own queued
    #   turns and queue limit, their link's expiry, the session's model.
    #   Never another participant's or the owner's usage, nor the session's.
    #
    # A later level (a tier that also shows the session's spend, say) adds
    # its row to LEVELS and its fields' sources in ParticipantReview: one
    # place each. A level this chi doesn't know (written by a newer chi, or
    # a hand-edited store) reads as DEFAULT, the narrowest: an unknown level
    # never shows more. See docs/internals/participants.md (Exposure).
    module ParticipantExposure
      OWN = "own"
      DEFAULT = OWN
      # level => the usage fields it shows, in the order the page reads them.
      LEVELS = {
        OWN => %i[spent cap queued queue_limit expires_at model].freeze
      }.freeze

      # +value+ as a level this chi knows, else DEFAULT.
      def self.level(value) = LEVELS.key?(value) ? value : DEFAULT

      # @return [Array<Symbol>] the fields +value+'s level shows
      def self.fields(value) = LEVELS.fetch(level(value))

      # The usage +value+'s level shows, each field read from +sources+
      # (field => a callable): only the fields shown are computed, and a
      # field a level names with no source raises (KeyError), never shows
      # nothing silently.
      # @param sources [Hash{Symbol => #call}]
      # @return [Hash{Symbol => Object}]
      def self.usage(value, sources)
        fields(value).to_h { |field| [field, sources.fetch(field).call] }
      end
    end
  end
end
