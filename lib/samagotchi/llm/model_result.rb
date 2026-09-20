# frozen_string_literal: true

module Samagotchi
  module LLM
    # Normalized result returned by every ModelBackend downstream of the agentic
    # loop. The loop lives INSIDE the backend (Option A), so raw provider tool
    # calls are never surfaced — `tool_calls` is always `nil` downstream.
    #
    # It deliberately mirrors the read surface Engine#run_turn and the renderers
    # (TerminalUI / Bridge) currently consume off KernelLoop::Result, so wiring
    # the seam in does not require changes to those consumers:
    #   .conversation, .canceled?, .cancellation_reason, .output, .exhausted?
    class ModelResult
      attr_reader :text, :tool_calls, :provider, :usage, :metadata,
                  :conversation, :canceled, :cancellation_reason, :exhausted

      def initialize(text:, tool_calls: nil, provider: nil, usage: nil, metadata: nil,
                     conversation: nil, canceled: false, cancellation_reason: nil, exhausted: false)
        @text = text
        @tool_calls = tool_calls
        @provider = provider
        @usage = usage
        @metadata = metadata
        @conversation = conversation
        @canceled = canceled
        @cancellation_reason = cancellation_reason
        @exhausted = exhausted
      end

      # Renderers call `result.output` (engine.rb, terminal_ui.rb). Alias to `text`.
      def output
        text
      end

      def canceled?
        !!canceled
      end

      def exhausted?
        !!exhausted
      end

      def resumable?
        exhausted?
      end

      def to_s
        text.to_s
      end
    end
  end
end
