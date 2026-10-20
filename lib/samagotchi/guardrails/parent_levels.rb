# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # The parent-answers level words and their one reading (#parse_level),
    # apart from the rest of ParentPolicy so Session (its parent_answers
    # setter) reads them without loading the guardrails.
    module ParentPolicy
      HARD = "hard"
      STANDARD = "standard"
      SOFT = "soft"
      # Strictest first: a session's own level may only move left of
      # config.yml's.
      ORDER = [HARD, STANDARD, SOFT].freeze
      # A session value that means "none of its own" (config's).
      UNSET = "default"

      # A level word as written anywhere (a session file, /parent-answers,
      # --parent-answers), stripped and case-blind.
      # @param word [String, Symbol, nil]
      # @return [String, Symbol] the level, :unset (nil, "" or "default":
      #   config's) or :invalid
      def self.parse_level(word)
        text = word.to_s.strip.downcase
        return :unset if text.empty? || text == UNSET

        ORDER.include?(text) ? text : :invalid
      end
    end
  end
end
