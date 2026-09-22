# frozen_string_literal: true

require "json"

module Samagotchi
  class BridgeClient
    # A Bridge event stream followed on a reader thread (BridgeClient#follow).
    #
    # Joins with `?snapshot=1`, so the first event is a `snapshot` frame, then
    # yields each live event parsed from JSON (string keys). When the
    # connection drops it reconnects with `Last-Event-ID`: the Bridge replays
    # what was missed, or sends a `reset` frame carrying a fresh snapshot when
    # it can't. Either snapshot kind means "re-render from here".
    #
    # When the Bridge stays unreachable through every reconnect delay, or does
    # not serve the session (404), it yields one synthetic
    # `{"type" => "stream_closed", "reason" => ...}` and stops. #close stops
    # it without that event.
    class EventStream
      DEFAULT_RECONNECT_DELAYS = [0.1, 0.25, 0.5, 1.0, 2.0].freeze
      HEADER_TIMEOUT = 5.0

      # @return [String, nil] the id of the last frame yielded (the reconnect cursor)
      attr_reader :last_event_id

      # @param client [BridgeClient]
      # @param snapshot [Boolean] join with a snapshot frame rather than a replay
      # @param reconnect_delays [Array<Float>] sleeps between failed attempts;
      #   one more failure than there are delays gives up
      # @yieldparam event [Hash] string-keyed event
      def initialize(client, snapshot: true, reconnect_delays: DEFAULT_RECONNECT_DELAYS, &on_event)
        @client = client
        @query = snapshot ? "?snapshot=1" : ""
        @reconnect_delays = reconnect_delays
        @on_event = on_event
        @last_event_id = nil
        @closed = false
        @sock = nil
        @mutex = Mutex.new
      end

      # @return [self]
      def start
        @thread = Thread.new { run }
        self
      end

      # Stop following: closes the socket under the reader so it wakes at once.
      # Safe to call from the event callback itself.
      def close
        sock = @mutex.synchronize do
          @closed = true
          @sock
        end
        begin
          sock&.close
        rescue IOError
          nil
        end
        @thread&.join(1) unless Thread.current == @thread
        self
      end

      def alive? = !!@thread&.alive?

      # @return [Thread, nil] the reader thread, nil when it did not finish in time
      def join(timeout = nil) = @thread&.join(timeout)

      private

      def run
        failures = 0
        until closed?
          outcome = read_connection
          break if closed?
          return finish("unknown_session") if outcome == :unknown_session

          if outcome == :events
            failures = 0
            next
          end

          failures += 1
          return finish("unreachable") if failures > @reconnect_delays.size

          sleep(@reconnect_delays[failures - 1])
        end
      end

      # One connection: :events when it yielded any, else why it failed.
      def read_connection
        sock, status = @client.connect_stream(query: @query, last_event_id: @last_event_id, timeout: HEADER_TIMEOUT)
        return :unreachable unless sock

        unless attach(sock)
          sock.close rescue nil
          return :closed
        end
        return :unknown_session if status == 404
        return :unreachable unless status == 200

        yielded = false
        parser = SSEParser.new
        loop do
          chunk = sock.readpartial(4096)
          parser.feed(chunk) do |frame|
            event = parse(frame[:data])
            next unless event

            @last_event_id = frame[:id] if frame[:id]
            yielded = true
            @on_event.call(event)
          end
        end
      rescue EOFError, IOError, SystemCallError
        yielded ? :events : :unreachable
      ensure
        detach(sock)
      end

      # Publish the socket for #close; false when already closed.
      def attach(sock)
        @mutex.synchronize do
          return false if @closed

          @sock = sock
        end
        true
      end

      def detach(sock)
        return unless sock

        @mutex.synchronize { @sock = nil if @sock.equal?(sock) }
        sock.close rescue nil
      end

      def parse(data)
        event = JSON.parse(data)
        event.is_a?(Hash) ? event : nil
      rescue JSON::ParserError
        nil
      end

      def finish(reason)
        @on_event.call({ "type" => "stream_closed", "reason" => reason }) unless closed?
      end

      def closed? = @mutex.synchronize { @closed }
    end
  end
end
