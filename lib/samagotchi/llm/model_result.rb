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
    #
    # A turn with no answer also carries .empty_steps (its empty
    # generations as model messages, which the loops keep out of the
    # conversation) and .empty_retries (the retries spent): the Engine saves
    # them on the turn's note for the UIs (TurnNote.empty).
    class ModelResult
      attr_reader :text, :conversation, :canceled, :cancellation_reason, :exhausted,
                  :tool_activity, :context_status, :pending_tool_calls, :empty_steps, :empty_retries

      def initialize(text:, conversation: nil, canceled: false, cancellation_reason: nil, exhausted: false,
                     tool_activity: [], context_status: nil, pending_tool_calls: false, empty_steps: [], empty_retries: 0)
        @empty_steps = Array(empty_steps)
        @empty_retries = empty_retries.to_i
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

      # The turn ended with nothing visible (no text). A cancelled turn or
      # one that can be continued is not an empty answer.
      def empty_answer?
        return false if canceled? || resumable?

        text.to_s.strip.empty?
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
