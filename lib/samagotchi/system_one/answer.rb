# frozen_string_literal: true

require_relative "question"

module Samagotchi
  module SystemOne
    # One judgment the System One API answered: for an :noul question,
    # `noul` is the probability of "yes"; a :choice answer carries `choice`
    # (the criterion chosen) and `confidence`; a :score answer carries
    # `score` (the level's index) and `confidence`. `probabilities` is what
    # the model put on each option, when it says.
    Answer = Data.define(:id, :type, :noul, :choice, :score, :confidence, :probabilities) do
      def initialize(id:, type:, noul: nil, choice: nil, score: nil, confidence: nil, probabilities: nil) = super

      # The response's answers entry as the wire sends it, or nil when it is
      # not usable: no type, a type the contract doesn't have, a noul
      # outside 0..1, a score that isn't a whole number, … A nil means "no
      # judgment for this question", never a guess.
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
          score = raw["score"]
          score = score.to_i if score.is_a?(Float) && score.to_i == score
          score.is_a?(Integer) && score >= 0 ? new(**answer, score: score) : nil
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
    end
  end
end
