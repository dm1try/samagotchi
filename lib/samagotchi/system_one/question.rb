# frozen_string_literal: true

module Samagotchi
  module SystemOne
    # The question types the judgment contract has.
    QUESTION_TYPES = %i[noul choice score].freeze

    # The questions of one ask, as an Array of Question: a Hash of
    # id => Question (or of wire fields), or an Array of Questions.
    def self.normalize_questions(questions)
      case questions
      when Hash then questions.map { |id, value| Question.coerce(id, value) }
      when Array then questions.map { |value| value.is_a?(Question) ? value : Question.coerce(value.to_s, value) }
      else raise ArgumentError, "questions must be a hash of id => question, got #{questions.class}"
      end
    end

    # One question of a System One request: id, type (:noul a yes/no
    # judgment, :choice one of the named criteria, :score one of the listed
    # levels), the instruction the model reads, and the criteria a :choice
    # (name => description or nil) or :score (a list of level names) needs.
    #
    #   Question.new(id: "git-push", type: "noul", instructions: "Would the user allow this git push?")
    Question = Data.define(:id, :type, :instructions, :criteria) do
      def initialize(id:, type:, instructions:, criteria: nil)
        id = id.to_s.strip
        raise ArgumentError, "SystemOne::Question needs an id" if id.empty?

        type = type.to_s.strip.downcase.to_sym
        unless QUESTION_TYPES.include?(type)
          raise ArgumentError, "question #{id}: type must be one of #{QUESTION_TYPES.join(", ")}, got #{type.inspect}"
        end

        instructions = instructions.to_s
        raise ArgumentError, "question #{id}: instructions are required" if instructions.strip.empty?

        super(id: id, type: type, instructions: instructions, criteria: criteria_for(id, type, criteria))
      end

      # The entry of the request's questions map.
      def to_wire
        wire = { "type" => type.to_s, "instructions" => instructions }
        wire["criteria"] = criteria unless criteria.nil?
        wire
      end

      # A Question as given, or a {type:, instructions:, criteria:} hash
      # (string or symbol keys) — what a caller has on hand.
      def self.coerce(id, value)
        return value if value.is_a?(Question)

        unless value.is_a?(Hash)
          raise ArgumentError, "question #{id}: expected a SystemOne::Question or a hash, got #{value.class}"
        end

        field = ->(name) { value.key?(name) ? value[name] : value[name.to_sym] }
        new(id: id, type: field.call("type"), instructions: field.call("instructions"), criteria: field.call("criteria"))
      end

      private

      def criteria_for(id, type, criteria)
        case type
        when :noul
          raise ArgumentError, "question #{id}: an noul question takes no criteria" unless criteria.nil?

          nil
        when :choice
          unless criteria.is_a?(Hash) && !criteria.empty? &&
                 criteria.all? { |name, description| !name.to_s.strip.empty? && (description.nil? || description.is_a?(String)) }
            raise ArgumentError, "question #{id}: a choice question takes criteria as {name => description or nil}"
          end

          criteria.to_h { |name, description| [name.to_s, description] }
        else
          unless criteria.is_a?(Array) && !criteria.empty? &&
                 criteria.all? { |level| level.is_a?(String) && !level.strip.empty? }
            raise ArgumentError, "question #{id}: a score question takes criteria as a list of level names"
          end

          criteria.map(&:to_s)
        end
      end
    end
  end
end
