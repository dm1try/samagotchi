# frozen_string_literal: true

require_relative "model_result"

module Samagotchi
  module LLM
    # Interface every model backend implements. The agentic loop lives INSIDE the
    # backend (Option A): a single `complete` call runs generation + tool rounds to
    # completion and returns a finished ModelResult.
    #
    # The signature mirrors KernelLoop#run so the native backend can forward the
    # streaming seam, Ctrl-C, model override, and tool-output cap unchanged. Any
    # extra surface lives on backend-specific subclasses, never on this interface.
    class ModelBackend
      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end
    end
  end
end

require_relative "native_backend"

module Samagotchi
  module LLM
    # Provider-based factory. Phase 1 knows only `:native`; later phases register
    # `:ruby_llm` and others here without touching callers.
    module Factory
      def self.factory(provider:, model_name:, kernel: nil, **_opts)
        case provider.to_sym
        when :native
          Samagotchi::LLM::NativeInContextBackend.new(kernel: kernel, model_name: model_name)
        else
          raise ArgumentError,
                "Unsupported model backend provider: #{provider.inspect} (known: :native)"
        end
      end
    end
  end
end
