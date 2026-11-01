# frozen_string_literal: true

require_relative "question"

module Samagotchi
  module SystemOne
    # One judgment the System One API answered: for an :noul question,
    # `noul` is the probability of "yes"; a :choice answer carries `choice`
    # (the criterion chosen) and `confidence`; a :score answer carries `score`
    # and `level`. The server's `score` is the probability-weighted level index
    # (Σ index × its probability), not a level number: with levels 0..n-1 it
    # sits between 0 and n-1, and for a two-level question it is exactly the
    # probability of level 1. `level` is the name of the level with the most
    # probability, from the response's `legend`. `probabilities` is what the
    # model put on each option, when it says (for a score, keyed by level index).
    Answer = Data.define(:id, :type, :noul, :choice, :score, :level, :confidence, :probabilities) do
      def initialize(id:, type:, noul: nil, choice: nil, score: nil, level: nil, confidence: nil, probabilities: nil) = super

      # The response's answers entry as the wire sends it, or nil when it is
      # not usable: no type, a type the contract doesn't have, a noul outside
      # 0..1, a score that isn't a number or past the last level, … A nil means
      # "no judgment for this question", never a guess.
      def self.from_wire(id, raw)
        return nil unless raw.is_a?(Hash)

        type = raw["type"].to_s.strip.downcase.to_sym
        return nil unless QUESTION_TYPES.include?(type)

        confidence = probability(raw["confidence"])
        odds = probabilities(raw["probabilities"])
        # A field the server sent but can't read is as unusable as a missing answer.
        return nil if bad_field(raw, "confidence", confidence) || bad_field(raw, "probabilities", odds)

        answer = { id: id, type: type, confidence: confidence, probabilities: odds }

        case type
        when :noul
          noul = probability(raw["noul"])
          noul.nil? ? nil : new(**answer, noul: noul)
        when :choice
          choice = raw["choice"].to_s.strip
          choice.empty? ? nil : new(**answer, choice: choice)
        else
          # The legend names the levels; without it there is no name for the
          # answer, but the weighted score still stands.
          legend = levels(raw["legend"])
          return nil if bad_field(raw, "legend", legend)

          score = level_score(raw["score"], legend, odds)
          score.nil? ? nil : new(**answer, score: score, level: top_level(legend, odds))
        end
      end

      # A value the wire sent that we could not parse.
      private_class_method def self.bad_field(raw, name, parsed)
        raw.key?(name) && !raw[name].nil? && parsed.nil?
      end

      # A probability as written: a number in 0..1, else nil.
      private_class_method def self.probability(value)
        return nil unless value.is_a?(Numeric)

        value = value.to_f
        return nil if value.nan? || value.infinite? || value.negative? || value > 1.0

        value
      end

      # The probabilities as sent: a map of option => number, or a list of
      # numbers (the options in order). Anything else is malformed.
      private_class_method def self.probabilities(value)
        if value.is_a?(Hash)
          pairs = value.map { |name, weight| [name.to_s, probability(weight)] }
          return nil if pairs.any? { |_name, weight| weight.nil? }

          pairs.to_h
        elsif value.is_a?(Array)
          weights = value.map { |weight| probability(weight) }
          return nil if weights.any?(&:nil?)

          weights
        end
      end

      # The legend as the server writes it: a map of level index => name, or
      # the level names in order. nil when absent or unreadable.
      private_class_method def self.levels(value)
        case value
        when Hash
          pairs = value.map { |index, name| [index.to_s.strip, name.to_s.strip] }
          return nil if pairs.empty? || pairs.any? { |index, name| !index.match?(/\A\d+\z/) || name.empty? }

          pairs.to_h { |index, name| [index.to_i, name] }
        when Array
          names = value.map { |name| name.to_s.strip }
          return nil if names.empty? || names.any?(&:empty?)

          names.each_with_index.to_h { |name, index| [index, name] }
        end
      end

      # The score as sent: the weighted level index, a whole number kept whole.
      # Not a number, or past the last level the response names, is no answer.
      private_class_method def self.level_score(value, legend, odds)
        return nil unless value.is_a?(Numeric)

        score = value.to_f
        return nil if score.nan? || score.infinite? || score.negative?

        count = legend&.size || (odds.is_a?(Array) ? odds.size : odds&.size)
        # A hair past the last level is the probabilities' own rounding, not a
        # level out of range.
        return nil if count && score > count - 1 + 1e-9

        score == score.to_i ? score.to_i : score
      end

      # The level with the most probability, named by the legend; nil when
      # there are no probabilities, or no legend to name it with.
      private_class_method def self.top_level(legend, odds)
        return nil if legend.nil? || legend.empty? || odds.nil? || odds.empty?

        weights = legend.keys.map { |index| odds.is_a?(Array) ? odds[index] : odds[index.to_s] }
        return nil if weights.any?(&:nil?)

        legend[legend.keys[weights.index(weights.max)]]
      end
    end
  end
end
