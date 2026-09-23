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

module Samagotchi
  module LLM
    # Marks an error that ended a turn with the conversation the loop had
    # built by then (the prompt plus completed tool iterations; a half
    # streamed reply is not kept), so the caller can keep it, as a cancel's
    # salvage does.
    module FailedTurn
      attr_accessor :partial_conversation

      # The innermost loop's conversation wins.
      # @return [Exception] +error+
      def self.attach(error, conversation)
        error.extend(self) unless error.is_a?(self)
        error.partial_conversation ||= conversation
        error
      end
    end
  end
end
