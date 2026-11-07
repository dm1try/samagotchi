# frozen_string_literal: true

# A thread-safe FIFO of lines for a loop's pending_input drain, the way a
# worker queues the input sent while its turn runs (Worker#pending_input_drain).
# A spec pushes lines and passes queue.method(:drain); KernelLoop drains it at
# iteration boundaries (Steer.inject!).
class PendingInputQueue
  def initialize
    @mutex = Mutex.new
    @messages = []
  end

  # Append a line; nil and "" are ignored.
  def push(text)
    text = text.to_s
    return if text.empty?

    @mutex.synchronize { @messages << text }
    nil
  end

  # Remove and return every queued line in order.
  # @return [Array<String>]
  def drain
    @mutex.synchronize do
      drained = @messages
      @messages = []
      drained
    end
  end

  def empty? = @mutex.synchronize { @messages.empty? }
end
