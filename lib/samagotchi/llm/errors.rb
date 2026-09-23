# frozen_string_literal: true

module Samagotchi
  module LLM
    # A request stopped by its CancellationController.
    class RequestCancelled < StandardError
      attr_reader :reason

      def initialize(reason = nil)
        @reason = reason
        super("request cancelled")
      end
    end

    # A request that kept failing on network errors until the retry budget
    # ran out.
    class RetryExhausted < StandardError
      attr_reader :attempts, :last_error

      def initialize(attempts:, last_error:, label: "llama.cpp")
        @attempts = attempts
        @last_error = last_error
        super("#{label} request failed after #{attempts} attempts: #{last_error.class}: #{last_error.message}")
      end
    end
  end
end
