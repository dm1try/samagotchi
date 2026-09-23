# frozen_string_literal: true

require_relative "backend"
require_relative "model_result"
require_relative "usage"

module Samagotchi
  module LLM
    # The raw-prompt loop as a backend: KernelLoop#run (llama.cpp /completion,
    # Gemma/Qwen prompt formats) with its result wrapped in a ModelResult, so
    # Engine and the TUI call every backend the same way.
    class NativeBackend < ModelBackend
      def initialize(kernel:)
        @kernel = kernel
      end

      def provider = :native

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        usage = UsageCollector.new
        kernel_result = @kernel.run(
          messages,
          max_iterations: max_iterations,
          on_stream_event: lambda { |event|
            usage.observe(event)
            on_stream_event&.call(event)
          },
          cancel_controller: cancel_controller,
          model_name: model_name,
          max_tool_output_chars: max_tool_output_chars,
          pending_input: pending_input
        )
        ModelResult.new(
          text: kernel_result.respond_to?(:output) ? kernel_result.output.to_s : kernel_result.to_s,
          tool_calls: nil,
          provider: :native,
          usage: usage.usage(prompt_text: Array(messages).sum("") { |message| message[:content].to_s }),
          conversation: kernel_result.respond_to?(:conversation) ? kernel_result.conversation : nil,
          canceled: kernel_result.respond_to?(:canceled?) && kernel_result.canceled?,
          cancellation_reason: kernel_result.respond_to?(:cancellation_reason) ? kernel_result.cancellation_reason : nil,
          exhausted: kernel_result.respond_to?(:exhausted) && kernel_result.exhausted,
          tool_activity: kernel_result.respond_to?(:tool_activity) ? kernel_result.tool_activity : [],
          context_status: kernel_result.respond_to?(:context_status) ? kernel_result.context_status : nil,
          pending_tool_calls: kernel_result.respond_to?(:pending_tool_calls) && kernel_result.pending_tool_calls
        )
      end
    end
  end
end
