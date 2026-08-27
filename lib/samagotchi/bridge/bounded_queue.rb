# frozen_string_literal: true

require "thread"

module Samagotchi
  class Bridge
    # A thread-safe bounded FIFO used to decouple the turn thread (which
    # enqueues SSE events from inside `Engine#emit_event`) from the dedicated
    # writer thread that serialises frames onto the socket.
    #
    # Enqueue (#push) is O(1) and never blocks the turn, even if the writer
    # thread is blocked on a slow / hung client socket. When the buffer is
    # full the oldest entry is dropped and an overflow marker is pushed in its
    # place so the writer can surface a reset to the client rather than
    # growing memory without bound.
    class BoundedQueue
      def initialize(capacity:)
        @capacity = [1, capacity].max
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @items = []
        @overflow_dropped = false
      end

      # Enqueue an item. Non-blocking; drops the oldest entry on overflow and
      # records that overflow happened.
      def push(item)
        @mutex.synchronize do
          @items << item
          @overflow_dropped = false if @items.size == 1
          while @items.size > @capacity
            @items.shift
            @overflow_dropped = true
          end
          @cv.broadcast
          nil
        end
      end

      # Pop the oldest item, waiting up to +timeout+ seconds (nil → block).
      # Returns nil on timeout or when drained.
      def pop(timeout)
        @mutex.synchronize do
          @cv.wait(@mutex, timeout) if timeout && @items.empty?

          @items.shift
        end
      end

      # @return [Boolean] true when an overflow has dropped entries since the
      #   last successful drain to empty.
      def overflow_dropped?
        @mutex.synchronize { @overflow_dropped }
      end

      # Clear the overflow flag after a consumer has handled it.
      def clear_overflow!
        @mutex.synchronize { @overflow_dropped = false }
      end

      def size
        @mutex.synchronize { @items.size }
      end

      def empty?
        @mutex.synchronize { @items.empty? }
      end
    end
  end
end
