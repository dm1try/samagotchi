# frozen_string_literal: true

require_relative "../token_usage"

module Samagotchi
  module LLM
    # A turn's token counts, never nil: what the server reported (:server),
    # else a chars/4 estimate (:estimate), else zeros (:none).
    Usage = Data.define(:prompt_tokens, :completion_tokens, :source) do
      # @return [Usage, nil] nil when the payload carries no counts
      def self.from_payload(payload)
        counts = TokenUsage.from_payload(payload)
        return nil unless counts

        new(prompt_tokens: counts[:prompt_tokens].to_i, completion_tokens: counts[:completion_tokens].to_i,
            source: :server)
      end

      def self.estimate(prompt_text:, completion_text:)
        new(prompt_tokens: TokenUsage.estimate(prompt_text.to_s), completion_tokens: TokenUsage.estimate(completion_text.to_s),
            source: :estimate)
      end

      def self.none = new(prompt_tokens: 0, completion_tokens: 0, source: :none)

      def total_tokens = prompt_tokens + completion_tokens
    end

    # Builds a turn's Usage from its stream events, the way SessionMetrics
    # counts them: server counts are cumulative per request, so each
    # generation keeps its highest; the prompt grows across a turn's
    # generations, so the last generation's prompt counts, and completions
    # add up. Without server counts, the streamed text is estimated.
    class UsageCollector
      def initialize
        @generations = []
      end

      def observe(event)
        case event[:type]
        when :generation_started
          @generations << { prompt: 0, completion: 0, server: false, text: +"" }
        when :generation_chunk
          @generations << { prompt: 0, completion: 0, server: false, text: +"" } if @generations.empty?
          record(@generations.last, event)
        end
      end

      # @param prompt_text [String, nil] what an estimate counts as the prompt
      def usage(prompt_text: nil)
        server = @generations.select { |generation| generation[:server] }
        unless server.empty?
          return Usage.new(prompt_tokens: server.last[:prompt], completion_tokens: server.sum { |g| g[:completion] },
                           source: :server)
        end

        text = @generations.sum("") { |generation| generation[:text] }
        return Usage.none if text.empty?

        Usage.estimate(prompt_text: prompt_text, completion_text: text)
      end

      private

      def record(generation, event)
        counts = Usage.from_payload(event[:payload])
        if counts
          generation[:server] = true
          generation[:prompt] = [generation[:prompt], counts.prompt_tokens].max
          generation[:completion] = [generation[:completion], counts.completion_tokens].max
        end
        generation[:text] << event[:content].to_s
      end
    end
  end
end
