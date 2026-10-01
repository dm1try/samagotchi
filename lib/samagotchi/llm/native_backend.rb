# frozen_string_literal: true

require_relative "backend"
require_relative "model_result"

module Samagotchi
  module LLM
    # The raw-prompt loop as a backend: KernelLoop#run (llama.cpp /completion,
    # Gemma/Qwen prompt formats), which returns a ModelResult itself, so
    # Engine and the TUI call every backend the same way.
    class NativeBackend < ModelBackend
      def initialize(kernel:)
        @kernel = kernel
      end

      def provider = :native

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        @kernel.run(
          messages,
          max_iterations: max_iterations,
          on_stream_event: ->(event) { on_stream_event&.call(event) },
          cancel_controller: cancel_controller,
          model_name: model_name,
          max_tool_output_chars: max_tool_output_chars,
          pending_input: pending_input
        )
      end
    end
  end
end
