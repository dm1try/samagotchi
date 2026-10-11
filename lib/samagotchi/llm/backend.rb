# frozen_string_literal: true

require_relative "../iteration_limit"
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
    #
    # +reasoning_since+: where the run a step-limit Continue resumes started
    # in +messages+ (Engine#run_turn resume_from:); the replies from there on
    # keep the model's reasoning (thought blocks), as within one run. nil:
    # the run starts here, as every other turn's does.
    class ModelBackend
      def complete(messages:, max_iterations: IterationLimit::DEFAULT, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil, reasoning_since: nil)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end
    end

    # Autoloaded: both require this file for their superclass, so a plain
    # require here would be circular.
    autoload :ChatLoop, File.expand_path("chat_loop", __dir__)
    autoload :NativeBackend, File.expand_path("native_backend", __dir__)
  end
end
