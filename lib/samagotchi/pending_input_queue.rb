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
    # +seq+ is the sender's own order number for it (the REPL numbers every
    # line it takes during a turn, so its leftovers keep send order across
    # this queue and its after-turn list: #drain_entries).
    def push(text, seq: nil)
      text = text.to_s
      return if text.empty?

      @mutex.synchronize { @messages << [seq, text] }
      nil
    end

    # Remove and return all queued messages in FIFO order. Non-blocking.
    # @return [Array<String>]
    def drain = drain_entries.map(&:last)

    # #drain with each message's +seq+ (nil when pushed without one).
    # @return [Array(Integer|nil, String)]
    def drain_entries
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
