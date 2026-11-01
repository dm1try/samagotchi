# frozen_string_literal: true

require_relative "../system_one/runs"

module Samagotchi
  module Plugin
    # ctx.judgments: what came of a bundle's own runs (docs/plugins.md,
    # Judgments), saved as later lines on them. A bundle's lines say it is
    # theirs (+by+ is its name), and it reaches no one else's runs.
    class Judgments
      MAX_TEXT = 200
      STRENGTHS = %w[strong weak].freeze

      # @param layer [#call] → the SystemOne::Judgments to save through
      # @param bundle [String]
      def initialize(layer, bundle:)
        @layer = layer
        @bundle = bundle
      end

      # The bundle's own word for its run: a raw value now, mapped at analysis.
      # @param run_id [String, nil] ctx.judge's Result#run_id, or what
      #   ctx.judge_later returned; nil (no run was saved) saves nothing
      # @param value [String] up to 200 characters
      # @param by [String, nil] what said it, after the bundle's name ("card":
      #   "check-in:card")
      # @param strength [String, nil] "strong" or "weak"
      # @param question [String, nil] the question it answers
      # @return [Boolean] whether it was saved
      # @raise [ArgumentError] a run of another bundle's, a bad value
      def label(run_id, value, by: nil, strength: nil, question: nil)
        value = text("label", value)
        raise ArgumentError, "strength: is #{STRENGTHS.join(" or ")}, not #{strength.inspect}" unless strength.nil? || STRENGTHS.include?(strength.to_s)
        return false unless own?(run_id)

        @layer.call.label(run_id, value, by: by.to_s.strip.empty? ? @bundle : "#{@bundle}:#{text("by", by)}",
                                         strength: strength&.to_s, question: question&.to_s)
      end

      # What the bundle did with the answer: never known when the run is saved.
      # @param what [String] up to 200 characters
      # @return [Boolean] whether it was saved
      # @raise [ArgumentError] a run of another bundle's, a bad value
      def acted(run_id, what)
        what = text("acted", what)
        return false unless own?(run_id)

        @layer.call.acted(run_id, what)
      end

      private

      # False for nil; a run that isn't this bundle's raises.
      def own?(run_id)
        return false if run_id.nil?

        judgment = SystemOne::Runs.judgment_of(run_id)
        return true if judgment&.start_with?("#{@bundle}.")

        raise ArgumentError, "#{run_id.inspect} is not a run of bundle #{@bundle}'s"
      end

      def text(what, value)
        word = value.to_s.strip
        return word if value.is_a?(String) && word.length.between?(1, MAX_TEXT)

        raise ArgumentError, "#{what} takes a String of 1 to #{MAX_TEXT} characters, not #{value.inspect[0, 40]}"
      end
    end
  end
end
