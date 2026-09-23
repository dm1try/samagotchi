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
    # The raw-prompt KernelLoop is NativeBackend; the chat loop is
    # RubyLLMBackend.
    class ModelBackend
      def complete(messages:, max_iterations: 100, on_stream_event: nil, cancel_controller: nil,
                   model_name: nil, max_tool_output_chars: nil, pending_input: nil)
        raise NotImplementedError, "#{self.class}#complete must be implemented"
      end
    end

    # Loaded on first use so the ruby_llm gem is only pulled in when that
    # backend is selected (ruby_llm_backend.rb requires this file for its
    # superclass, so a plain require here would be circular).
    autoload :RubyLLMBackend, File.expand_path("ruby_llm_backend", __dir__)
    autoload :NativeBackend, File.expand_path("native_backend", __dir__)

    # Provider-based factory: `:native` (NativeBackend around the KernelLoop)
    # and `:ruby_llm`; later phases register others here without touching
    # callers.
    module Factory
      # The default backend when no selection is made.
      DEFAULT_PROVIDER = :native

      # Single source of truth for resolving the backend provider. Prefers an
      # explicit `provider:` value when given; otherwise falls back to
      # `ENV["SAMAGOTCHI_BACKEND"]`. Blank / whitespace / nil all resolve to
      # `:native`.
      #
      # Note the blank handling: `ENV["SAMAGOTCHI_BACKEND"] = ""` is a *truthy*
      # string in Ruby, so the naive `ENV["..."] || :native` one-liner yields
      # `:""` -> `Factory#factory` hits its else -> `ArgumentError` instead of
      # the `:native` default. We `.to_s.strip` first and resolve to a symbol
      # here so Factory never sees a stray `nil` (which would raise NoMethodError
      # on `nil.to_sym` rather than a clean ArgumentError).
      def self.resolve_provider(provider = nil, env: ENV)
        raw = provider.nil? ? env["SAMAGOTCHI_BACKEND"] : provider
        raw = raw.to_s.strip
        raw.empty? ? DEFAULT_PROVIDER : raw.to_sym
      end

      def self.factory(provider:, model_name:, kernel: nil, base_url: nil, **_opts)
        case resolve_provider(provider)
        when :native
          Samagotchi::LLM::NativeBackend.new(kernel: kernel)
        when :ruby_llm
          Samagotchi::LLM::RubyLLMBackend.new(model_name: model_name, kernel: kernel, base_url: base_url)
        else
          raise ArgumentError,
                "Unsupported model backend provider: #{resolve_provider(provider).inspect} (known: :native, :ruby_llm)"
        end
      end
    end
  end
end
