# frozen_string_literal: true

require "json"

module Samagotchi
  class Bridge
    # Per-connection SSE writer.
    #
    # This object doubles as the per-connection live observer wired into the
    # Engine via `Engine#subscribe`: its `#call` is invoked synchronously from
    # `Engine#emit_event` inside the turn thread, so it must be strictly
    # non-blocking — it only enqueues onto a bounded queue and returns. A
    # dedicated writer thread (the connection's own thread) drains the queue
    # and serialises SSE frames onto the socket, so a slow / hung client can
    # never stall the running turn or other subscribers.
    #
    # #serve! performs the replay wiring in the correctness-ordered sequence
    # mandated by the bridge design invariants:
    #   1. subscribe the live queue FIRST
    #   2. capture `event_count` (snapshot)
    #   3. replay buffered `seq ∈ (from_seq, snapshot]`
    #   4. drain the live queue for `seq > snapshot`
    # which guarantees no gap and no overlap; a per-connection `event_seq`
    # high-water mark de-duplicates the subscribe→capture window.
    class SSEWriter
      DEFAULT_MAX_QUEUE = 1024
      DEFAULT_HEARTBEAT_INTERVAL = 15.0

      # @param engine [Samagotchi::Engine] the owning engine (live fan-out)
      # @param ring [Samagotchi::Bridge::RingBuffer] shared capture buffer
      # @param session_id [String]
      # @param last_event_id [String, nil] reconnect cursor (or ?from_seq=)
      # @param snapshot_provider [#call] -> {status:, message_count:,
      #   last_prompt:, event_seq:}
      # @param bridge [Samagotchi::Bridge, nil] for stop signalling
      # @param max_queue [Integer] bounded-queue capacity
      # @param heartbeat_interval [Float] idle-seconds between `: ping` frames
      def initialize(engine:, ring:, session_id:, last_event_id: nil,
                     snapshot_provider:, bridge: nil,
                     max_queue: DEFAULT_MAX_QUEUE,
                     heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL)
        @engine = engine
        @ring = ring
        @session_id = session_id
        @last_event_id = last_event_id
        @snapshot_provider = snapshot_provider
        @bridge = bridge
        @max_queue = max_queue
        @heartbeat_interval = heartbeat_interval

        @queue = BoundedQueue.new(capacity: @max_queue)
        @high_water = (@last_event_id || "0").to_i
        @handle = nil
        @serving = false
        @mutex = Monitor.new
      end

      # Non-blocking enqueue used as the per-connection live observer. Any
      # caller runs in the turn thread; must never block. Events already
      # served (seq <= high water) are dropped to avoid replay overlap.
      def call(payload)
        seq = payload[:event_seq]
        return if seq && seq <= @high_water

        @queue.push(payload)
      rescue StandardError
        # Enqueue isolation is best-effort; a bad payload must not break the
        # running turn.
        nil
      end

      # Run the serve loop on the caller's (connection) thread. Blocks until
      # the client disconnects or the bridge stops.
      def serve!(io)
        @serving = true
        write_sse_headers(io)
        begin
          # (1) subscribe the live queue FIRST.
          @handle = @engine.subscribe(observer: self)
          # (2) capture the snapshot sequence.
          snapshot_seq = @engine.event_count
          # (3) replay buffered (from_seq, snapshot].
          replay!(io, snapshot_seq)
          # (4) drain live events for seq > snapshot.
          drain!(io)
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          # Client hung up; nothing to do.
        ensure
          @serving = false
          @engine.unsubscribe(handle: @handle) if @handle
        end
      end

      private

      def replay!(io, snapshot_seq)
        from_seq = @high_water
        oldest = @ring.oldest_seq
        if from_seq > snapshot_seq || (from_seq.positive? && oldest && from_seq < oldest)
          # Cursor is ahead of the engine (worker restarted) or behind the
          # ring's buffered window (overflow): the server cannot replay the
          # gap, so it emits a reset marker and the client re-syncs. A cold
          # connect (from_seq == 0) replays the whole served window, and a
          # fully caught-up cursor (from_seq == snapshot_seq) is NOT a reset
          # case — it gets an empty replay and holds for live events.
          emit_reset(io, snapshot_seq)
        else
          @ring.events_in_range(after_seq: from_seq, to_seq: snapshot_seq).each { |record| write_event(io, record[:data]) }
        end
      end

      def drain!(io)
        loop do
          payload = @queue.pop(@heartbeat_interval)
          if payload
            if payload.is_a?(Hash) && payload[:sse_reset]
              emit_reset(io, payload[:event_seq])
              next
            end

            write_event(io, payload)
            # A fresh overflow since the last drain => the client fell too far
            # behind; nudge a reconnect rather than flooding more events.
            emit_reset(io, @engine.event_count) if @queue.overflow_dropped?
            @queue.clear_overflow!
          elsif @bridge&.stopped?
            break
          else
            write_heartbeat(io)
          end
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        nil
      end

      def write_event(io, event)
        seq = event[:event_seq]
        return if seq && seq <= @high_water

        write_frame(io, seq: seq, data: event)
        @high_water = seq if seq && seq > @high_water
      end

      def write_sse_headers(io)
        io.write(
          "HTTP/1.1 200 OK\r\n" \
          "Content-Type: text/event-stream\r\n" \
          "Cache-Control: no-cache\r\n" \
          "Connection: keep-alive\r\n" \
          "X-Accel-Buffering: no\r\n" \
          "Access-Control-Allow-Origin: *\r\n" \
          "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" \
          "Access-Control-Allow-Headers: Content-Type, Last-Event-ID\r\n" \
          "\r\n"
        )
        io.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        raise
      end

      # Serialise one SSE event: an `id:` line (the replay cursor), an optional
      # `event:` line for EventSource.addEventListener, one or more `data:` lines,
      # and the terminating blank line.
      def write_frame(io, seq:, data:)
        lines = []
        lines << "id: #{seq}"
        event_type = data.is_a?(Hash) && (data[:type] || data["type"])
        lines << "event: #{event_type}" if event_type && !event_type.to_s.empty?
        JSON.generate(data).each_line { |line| lines << "data: #{line.chomp}" }
        io.write(lines.join("\r\n") + "\r\n\r\n")
        io.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        raise
      end

      def write_heartbeat(io)
        io.write(": ping\r\n\r\n")
        io.flush
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        raise
      end

      # Emit a control frame carrying the current snapshot so a client that
      # cannot replay can re-derive state, then continue live.
      def emit_reset(io, current_seq)
        snapshot = @snapshot_provider.call
        write_frame(io, seq: current_seq, data: { type: :reset, session_state_snapshot: snapshot })
      rescue Errno::EPIPE, Errno::ECONNRESET, IOError
        raise
      end

      def closed?
        @mutex.synchronize { !@serving }
      end
    end
  end
end
