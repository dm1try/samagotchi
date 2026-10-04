# frozen_string_literal: true

require_relative "../token_usage"

module Samagotchi
  module LLM
    # A response's token counts, never nil: what the server reported
    # (:server), else zeros (:none). +cached_tokens+ is the prompt the server
    # reused from its cache, +cache_write_tokens+ what it wrote to it
    # (OpenRouter reports those for Anthropic models); 0 when not reported.
    Usage = Data.define(:prompt_tokens, :completion_tokens, :source, :cached_tokens, :cache_write_tokens) do
      # @return [Usage, nil] nil when the payload carries no counts
      def self.from_payload(payload)
        counts = TokenUsage.from_payload(payload)
        return nil unless counts

        new(prompt_tokens: counts.prompt_tokens.to_i, completion_tokens: counts.completion_tokens.to_i,
            source: :server, cached_tokens: counts.cached_tokens.to_i,
            cache_write_tokens: counts.cache_write_tokens.to_i)
      end

      def self.none = new(prompt_tokens: 0, completion_tokens: 0, source: :none)

      def initialize(prompt_tokens:, completion_tokens:, source:, cached_tokens: 0, cache_write_tokens: 0)
        super
      end

      def total_tokens = prompt_tokens + completion_tokens

      # The request's prompt-cache counts for a :generation_completed event
      # and the log ({} when the server reported none).
      def cache_fields
        return {} unless source == :server

        TokenUsage.cache_fields(prompt: prompt_tokens, cached: cached_tokens, cache_write: cache_write_tokens)
      end
    end
  end
end
