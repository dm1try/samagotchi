# frozen_string_literal: true

require "monitor"

module Samagotchi
  class Bridge
    # A bounded, thread-safe in-memory ring buffer of emitted events, keyed by
    # the Engine's monotonic `event_seq`. One shared instance per bridge
    # (owned by the capture observer) so that any client reconnecting from a
    # given `Last-Event-ID` can replay the same window. Oldest entries are
    # dropped past the capacity, which is what makes a too-old reconnect
    # replay nothing and fall back to a reset marker.
    #
    # This is in-memory sequence (ordering + short reconnect), not durable
    # cross-process resume — durable resume is a staged next step.
    class RingBuffer
      def initialize(capacity: 256)
        @capacity = [1, capacity].max
        @mutex = Monitor.new
        @events = [] # Array<{seq:, data:}>
      end

      # Append +data+ keyed by +seq+ (drop oldest beyond capacity).
      def push(seq:, data:)
        @mutex.synchronize do
          @events << { seq: seq, data: data }
          @events.shift until @events.size <= @capacity
          nil
        end
      end

      # Buffered events with seq in the half-open range (after_seq, to_seq].
      # Returns shallow copies so callers may serialise without holding the
      # lock (or retaining the structure).
      def events_in_range(after_seq:, to_seq:)
        return [] if to_seq <= after_seq

        @mutex.synchronize do
          @events.select { |e| e[:seq] > after_seq && e[:seq] <= to_seq }.map { |e| e.dup }
        end
      end

      # @return [Integer, nil] the highest seq buffered so far.
      def last_seq
        @mutex.synchronize { @events.last&.[](:seq) }
      end

      # @return [Integer, nil] the lowest seq buffered so far.
      def oldest_seq
        @mutex.synchronize { @events.first&.[](:seq) }
      end

      def empty?
        @mutex.synchronize { @events.empty? }
      end
    end
  end
end
