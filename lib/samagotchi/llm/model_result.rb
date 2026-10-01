# frozen_string_literal: true

module Samagotchi
  module LLM
    # Normalized result returned by every ModelBackend downstream of the agentic
    # loop (the loop lives inside the backend). What Engine#run_turn and the
    # renderers (TerminalUI / Bridge) read: .output (= .text, and .to_s, which
    # is how the :turn_completed `result:` reaches JSON), .conversation,
    # .canceled?, .cancellation_reason, .exhausted?, .resumable?,
    # .empty_answer?, plus the native loop's .tool_activity, .context_status
    # and .pending_tool_calls, which the interactive renderer needs.
    class ModelResult
      attr_reader :text, :conversation, :canceled, :cancellation_reason, :exhausted,
                  :tool_activity, :context_status, :pending_tool_calls

      def initialize(text:, conversation: nil, canceled: false, cancellation_reason: nil, exhausted: false,
                     tool_activity: [], context_status: nil, pending_tool_calls: false, empty_answer: false)
        @empty_answer = empty_answer
        @text = text
        @conversation = conversation
        @canceled = canceled
        @cancellation_reason = cancellation_reason
        @exhausted = exhausted
        @tool_activity = Array(tool_activity)
        @context_status = context_status
        @pending_tool_calls = pending_tool_calls
      end

      # Renderers call `result.output` (engine.rb, terminal_ui.rb). Alias to `text`.
      def output
        text
      end

      def canceled?
        !!canceled
      end

      # The turn ended with nothing visible: no text, or the chat loop's
      # placeholder (empty_answer:). A cancelled turn or one that can be
      # continued is not an empty answer.
      def empty_answer?
        return false if canceled? || resumable?

        !!@empty_answer || text.to_s.strip.empty?
      end

      def exhausted?
        !!exhausted
      end

      def pending_tool_calls?
        !!pending_tool_calls
      end

      # KernelLoop only marks a run exhausted when it stopped on pending tool
      # calls, so exhausted? alone already means "resumable".
      def resumable?
        exhausted?
      end

      def to_s
        text.to_s
      end
    end
  end
end
