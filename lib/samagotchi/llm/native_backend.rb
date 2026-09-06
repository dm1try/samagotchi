# frozen_string_literal: true

require_relative "model_result"

module Samagotchi
  module LLM
    # Thin adapter over the existing in-context local path (Client + KernelLoop).
    # Holds no behavior of its own: it delegates to KernelLoop#run and wraps the
    # outcome in a ModelResult. All tool-call normalization (ToolCallParser)
    # and thought-stripping stay in KernelLoop/ToolCallParser, unchanged.
    #
    # The backend instance is stateless w.r.t. provider specifics: it owns a
    # KernelLoop (injected or built fresh) but memoizes nothing on itself, so
    # multiple backends can be created per SessionManager worker without shared
    # mutable state.
    class NativeInContextBackend < ModelBackend
      def initialize(kernel: nil, model_name: nil, client: nil, verbose: false,
                     log_file: nil, profile: nil, no_interrupt: false)
        @kernel = kernel || Samagotchi::KernelLoop.new(
          client: client,
          verbose: verbose,
          log_file: log_file,
          profile: profile,
          model_name: model_name,
          no_interrupt: no_interrupt
        )
      end

      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil)
        kernel_result = @kernel.run(
          messages,
          max_iterations: max_iterations,
          on_stream_event: on_stream_event,
          cancel_controller: cancel_controller,
          model_name: model_name,
          max_tool_output_chars: max_tool_output_chars
        )

        Samagotchi::LLM::ModelResult.new(
          text: kernel_result.respond_to?(:output) ? kernel_result.output.to_s : kernel_result.to_s,
          tool_calls: nil,
          provider: :native,
          conversation: kernel_result.respond_to?(:conversation) ? kernel_result.conversation : nil,
          canceled: kernel_result.respond_to?(:canceled?) && kernel_result.canceled?,
          cancellation_reason: kernel_result.respond_to?(:cancellation_reason) ? kernel_result.cancellation_reason : nil,
          exhausted: kernel_result.respond_to?(:exhausted) && kernel_result.exhausted
        )
      end
    end
  end
end
