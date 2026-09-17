# frozen_string_literal: true

module Samagotchi
  # Thread-safe FIFO of user steering messages submitted while a turn is
  # running. UIs (TUI, web, background workers) are push-only producers;
  # KernelLoop drains the queue at iteration boundaries and injects the
  # messages into the conversation. True mid-stream injection is impossible
  # with llama.cpp's /completion API, so draining only happens between full
  # LLM responses / tool dispatches.
  #
  # Usage:
  #   queue = PendingInputQueue.new
  #   queue.push("please also check the specs")
  #   kernel.run(messages, pending_input: queue.method(:drain))
  class PendingInputQueue
    def initialize
      @mutex = Mutex.new
      @messages = []
    end

    # Append a message to the queue. Nil/empty strings are ignored.
    def push(text)
      text = text.to_s
      return if text.empty?

      @mutex.synchronize { @messages << text }
      nil
    end

    # Remove and return all queued messages in FIFO order. Non-blocking.
    # @return [Array<String>]
    def drain
      @mutex.synchronize do
        drained = @messages
        @messages = []
        drained
      end
    end

    def empty?
      @mutex.synchronize { @messages.empty? }
    end

    def size
      @mutex.synchronize { @messages.size }
    end
  end
end
