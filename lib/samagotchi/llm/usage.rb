# frozen_string_literal: true

require_relative "../token_usage"

module Samagotchi
  module LLM
    # A response's token counts, never nil: what the server reported
    # (:server), else zeros (:none).
    Usage = Data.define(:prompt_tokens, :completion_tokens, :source) do
      # @return [Usage, nil] nil when the payload carries no counts
      def self.from_payload(payload)
        counts = TokenUsage.from_payload(payload)
        return nil unless counts

        new(prompt_tokens: counts[:prompt_tokens].to_i, completion_tokens: counts[:completion_tokens].to_i,
            source: :server)
      end

      def self.none = new(prompt_tokens: 0, completion_tokens: 0, source: :none)

      def total_tokens = prompt_tokens + completion_tokens
    end
  end
end
