# frozen_string_literal: true

require_relative "../context_usage"

module Samagotchi
  class Bridge
    # What an SSE client gets for an engine event (SSEWriter#write_event, live
    # and replayed alike). A :generation_chunk carries chi's own counts
    # (`counts`, ContextUsage.normalize of the provider's payload) instead of
    # the provider's raw `payload`, and no raw `content` (the chat loop's is
    # reasoning + content again, the native loop's the raw stream with its
    # tool-call bytes and thought tags): clients read `text`, `thinking`,
    # `tool_call` and `counts`, never a provider's payload shape.
    # :tool_call_started omits the model's `call`; clients render its row from
    # the other fields. :turn_completed omits `result`; `turn_summary.output`
    # carries the answer. `?raw=1` on the worker's stream skips this (debugging).
    #
    # Pure: the event is the one hash SessionObserver hands every observer
    # (the ring, TurnAccumulator, the other writers, SessionMetrics, hooks),
    # so it is never mutated; keys are added or removed on a copy, and any
    # key not named here (event_seq included) passes through.
    module ClientEvent
      # The counts a client gets: ctx_pct stays out, as normalize computes it
      # without the session's LLM context budget (the client counts
      # total_tokens against the window or budget itself).
      COUNT_KEYS = %i[prompt_tokens completion_tokens total_tokens context_window_tokens].freeze

      module_function

      # @param event [Hash] the engine's event (symbol keys; its payload has
      #   string keys)
      # @return [Hash] the event as clients get it: a copy for a
      #   projected event, the same object for every other event
      def project(event)
        return event unless event.is_a?(Hash)

        case event[:type].to_s
        when "generation_chunk"
          projected = event.except(:payload, :content)
          found = counts(event[:payload])
          found ? projected.merge(counts: found) : projected
        when "tool_call_started" then event.except(:call)
        when "turn_completed" then event.except(:result)
        else event
        end
      end

      # The payload's normalized counts, nil keys left out; nil when the
      # payload reports none (a missing key means unknown, never 0).
      # @return [Hash, nil]
      def counts(payload)
        usage = ContextUsage.normalize(payload)
        found = usage&.slice(*COUNT_KEYS)&.compact
        found.nil? || found.empty? ? nil : found
      end
    end
  end
end
