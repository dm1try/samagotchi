# frozen_string_literal: true

require_relative "model_result"

module Samagotchi
  module LLM
    # Interface every model backend implements. The agentic loop lives INSIDE the
    # backend (Option A): a single `complete` call runs generation + tool rounds to
    # completion and returns a finished ModelResult.
    #
    # The signature mirrors KernelLoop#run so any provider backend can forward the
    # streaming seam, Ctrl-C, model override, and tool-output cap unchanged. Any
    # extra surface lives on backend-specific subclasses, never on this interface.
    #
    # The raw-prompt KernelLoop is NativeBackend; the chat loop is ChatLoop.
    class ModelBackend
      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end
    end

    # Autoloaded: both require this file for their superclass, so a plain
    # require here would be circular.
    autoload :ChatLoop, File.expand_path("chat_loop", __dir__)
    autoload :NativeBackend, File.expand_path("native_backend", __dir__)
  end
end
