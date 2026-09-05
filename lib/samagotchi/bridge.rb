# frozen_string_literal: true

require "socket"
require "json"
require "uri"
require "fileutils"
require "securerandom"
require "time"

require_relative "bridge/bounded_queue"
require_relative "bridge/ring_buffer"
require_relative "bridge/sse_writer"
require_relative "session"

module Samagotchi
  # Bridge is an optional HTTP transport that lets an external web / desktop
  # client reach the owner process (the forked session-worker) and receive the
  # Engine's live event stream via Server-Sent Events, and optionally create a
  # turn via HTTP POST.
  #
  # Design invariants (see multi_ui_architecture):
  # * Reuses `Engine#subscribe` for SSE fan-out — never a second Engine, never
  #   `run_turn` across the thread/process boundary. POST reuses the
  #   `SessionManager` file-IPC input path.
  # * One capture observer fills a shared ring buffer; each connection gets a
  #   per-connection live queue (see SSEWriter).
  # * Binds 127.0.0.1 only. There is NO auth: binding 0.0.0.0 exposes remote
  #   turn-execution (RCE). Documented, not fixed.
  # * Optional at runtime: this module is never loaded unless explicitly
  #   engaged as a transport.
  class Bridge
    DEFAULT_BIND = "127.0.0.1"
    SIDECAR_FILE = "bridge.json"
    DEFAULT_RING_CAPACITY = 256
    DEFAULT_HEARTBEAT_INTERVAL = 15.0

    # @param engine [Samagotchi::Engine] the owning engine (must already live
    #   in this process)
    # @param state_dir [String] the session state directory root
    # @param session_id [String] this bridge's session id
    # @param bind [String] bind address (127.0.0.1 only)
    # @param port [Integer] port to bind (0 → OS-assigned, read back)
    # @param ring_capacity [Integer] shared ring-buffer capacity
    # @param heartbeat_interval [Float] idle `: ping` seconds
    def initialize(engine:, state_dir:, session_id:, bind: DEFAULT_BIND,
                   port: 0, ring_capacity: DEFAULT_RING_CAPACITY,
                   heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL)
      @engine = engine
      @state_dir = state_dir
      @session_id = session_id
      @bind = bind
      @port = port
      @ring = RingBuffer.new(capacity: ring_capacity)
      @heartbeat_interval = heartbeat_interval

      @capture_handle = nil
      @server = nil
      @accept_thread = nil
      @connection_threads = []
      @stopped = false
      @mutex = Monitor.new
    end

    # @return [Boolean] whether the server has been stopped.
    def stopped?
      @mutex.synchronize { @stopped }
    end

    # Bind the listen socket (OS-assigned when port == 0), register the shared
    # capture observer, start the acceptor thread, and write the port sidecar.
    # Non-blocking: returns once the socket is listening.
    # @return [self]
    def start
      @server = TCPServer.new(@bind, @port)
      @port = @server.local_address.ip_port
      @capture_handle = @engine.subscribe(observer: capture_observer)
      @accept_thread = Thread.new { accept_loop }
      @accept_thread.report_on_exception = false
      write_sidecar
      self
    rescue StandardError => e
      stop
      raise e
    end

    # Stop the acceptor and release the socket. Does not stop the owning turn.
    # Joins the acceptor thread so the process can exit cleanly (Ruby waits for
    # a thread blocked in IO.select at VM shutdown).
    def stop
      @mutex.synchronize { @stopped = true }
      begin
        @server&.close
      rescue StandardError
        nil
      end
      @capture_handle&.unsubscribe
      @connection_threads.each { |t| t.kill rescue nil }
      @connection_threads.clear
      @accept_thread&.join(2)
      nil
    end

    private

    # The single shared capture observer: appends every event to the ring.
    # O(1) and non-blocking.
    def capture_observer
      @capture_proc ||= proc do |event|
        @ring.push(seq: event[:event_seq], data: event)
      rescue StandardError
        nil
      end
    end

    def accept_loop
      loop do
        break if stopped? || @server.closed?

        begin
          rs, = IO.select([@server], nil, nil, 0.5)
        rescue IOError
          break
        end

        next unless rs

        client =
          begin
            @server.accept
          rescue IOError, Errno::EBADF
            break
          end

        Thread.new { handle_connection(client) }.tap do |t|
          t.report_on_exception = false
          @connection_threads << t
        end
      end
    rescue StandardError
      nil
    end

    # One thread per connection. Short-lived endpoints (POST / state) answer
    # and keep the connection open for another request; the SSE endpoint owns
    # the connection until the client disconnects or the bridge stops.
    def handle_connection(io)
      io.binmode
      loop do
        request = read_request(io)
        break if request.nil?

        method = request[:method].to_s.upcase
        headers = request[:headers]

        if method == "OPTIONS"
          write_json(io, 204, cors, {})
        elsif (m = stream_match(request[:path])) && method == "GET"
          cursor = reconnect_cursor(headers, request[:query])
          serve_sse(io, m[1], last_event_id: cursor)
          break # SSE owns the connection until the client disconnects.
        elsif (m = cancel_match(request[:path])) && method == "POST"
          payload, status, body = handle_cancel(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = answer_match(request[:path])) && method == "POST"
          payload, status, body = handle_answer(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = turn_match(request[:path])) && method == "POST"
          payload, status, body = handle_post_turn(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = state_match(request[:path])) && method == "GET"
          payload, status, body = handle_state(m[1])
          write_json(io, status, payload, body)
        else
          write_json(io, 404, { "Allow" => "GET, POST, OPTIONS" },
                     { error: "not_found", path: request[:path] })
        end

        break if close_after_request?(headers)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      begin
        io.close
      rescue StandardError
        nil
      end
    end

    # Serve an SSE stream. Owns the connection until the client disconnects.
    # The connection thread IS the writer thread: serve! blocks until then.
    def serve_sse(io, session_id, last_event_id:)
      unless own_session?(session_id)
        write_json(io, 404, {}, { error: "unknown_session" })
        return
      end

      writer = SSEWriter.new(
        engine: @engine,
        ring: @ring,
        session_id: @session_id,
        last_event_id: last_event_id,
        snapshot_provider: -> { @engine.session_state_snapshot },
        bridge: self,
        heartbeat_interval: @heartbeat_interval
      )
      writer.serve!(io)
    end

    def cors
      {
        "Access-Control-Allow-Origin" => "*",
        "Access-Control-Allow-Methods" => "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers" => "Content-Type, Last-Event-ID"
      }
    end

    def stream_match(path)
      %r|\A/session/([^/]+)/stream\z|u.match(path.to_s)
    end

    def turn_match(path)
      %r|\A/session/([^/]+)/turn\z|u.match(path.to_s)
    end

    def state_match(path)
      %r|\A/session/([^/]+)/state\z|u.match(path.to_s)
    end

    def cancel_match(path)
      %r|\A/session/([^/]+)/cancel\z|u.match(path.to_s)
    end

    def answer_match(path)
      %r|\A/session/([^/]+)/answer\z|u.match(path.to_s)
    end

    # Cancel the active turn on this session's engine, if any.
    # Returns [headers, status, body].
    def handle_cancel(session_id, body)
      unless own_session?(session_id)
        return [{}, 404, { error: "unknown_session" }]
      end

      # Optional reason from JSON body
      reason = :manual
      if body && !body.strip.empty?
        parsed = parse_json(body)
        r = parsed.is_a?(Hash) ? (fetched(parsed, "reason") || fetched(parsed, "cancellation_reason")) : nil
        reason = r.to_s.strip.empty? ? :manual : r.to_sym
      end

      if @engine.turn_running? && @engine.active_cancel_controller
        ok = @engine.cancel_current_turn!(reason)
        return [{}, 202, { status: "cancel_requested", session_id: @session_id, reason: reason.to_s }] if ok

        [{}, 409, { error: "cancel_failed", detail: "could not cancel", session_id: @session_id }]
      else
        [{}, 409, { error: "not_running", detail: "no active turn to cancel", session_id: @session_id }]
      end
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    def handle_answer(session_id, body)
      unless own_session?(session_id)
        return [{}, 404, { error: "unknown_session" }]
      end
      parsed = parse_json(body)
      unless parsed.is_a?(Hash)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }]
      end
      qid = fetched(parsed, "id") || fetched(parsed, "question_id")
      selected = fetched(parsed, "selected") || fetched(parsed, "selection")
      freeform = fetched(parsed, "freeform") || fetched(parsed, "other")
      # Support nested answer
      if parsed["answer"].is_a?(Hash)
        ans = parsed["answer"]
        qid ||= fetched(ans, "id")
        selected ||= fetched(ans, "selected")
        freeform ||= fetched(ans, "freeform")
      end
      if qid.to_s.strip.empty?
        return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "id required" }]
      end
      begin
        result = @engine.answer_question(id: qid, selected: selected, freeform: freeform)
        [{}, 200, { status: "answered", session_id: session_id, answer: result }]
      rescue ArgumentError => e
        [{}, 400, { error: "invalid_answer", detail: e.message }]
      rescue StandardError => e
        [{}, 500, { error: "bridge_error", detail: e.message }]
      end
    end

    # Create a turn via file IPC (fire-and-forget). Returns [headers, status, body].
    def handle_post_turn(session_id, body)
      parsed = parse_json(body)
      unless parsed.is_a?(Hash)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }]
      end

      sid = fetched(parsed, "session_id")
      prompt = fetched(parsed, "prompt")
      if sid.to_s.strip.empty? || prompt.to_s.strip.empty?
        return [{ "Allow" => "POST" }, 400,
                { error: "missing_fields", detail: "session_id and prompt are required" }]
      end

      enqueued_id = SecureRandom.uuid
      return [{}, 500, { error: "enqueue_failed", detail: "could not write turn input" }] \
        unless enqueue_turn(session_id: sid, prompt: prompt)

      [{}, 202, { status: "accepted", enqueued_id: enqueued_id, session_id: sid }]
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # Read-only snapshot surface. AC #4: too-old reconnects re-derive state
    # from here.
    def handle_state(session_id)
      unless own_session?(session_id)
        return [{}, 404, { error: "unknown_session" }]
      end

      [{}, 200, { session_id: @session_id, session_state_snapshot: @engine.session_state_snapshot }]
    end

    # A per-session bridge only ever owns one Engine (for @session_id). The
    # stream and state surfaces must serve that session and nothing else —
    # serving a different id's data (or closing with no response) would be a
    # cross-session leak. POST/turn enqueue stays lenient (fire-and-forget to
    # another worker's input dir) and validates via write_turn_input.
    def own_session?(session_id)
      session_id.to_s == @session_id.to_s
    end

    # Write a turn into the target session's input dir, reusing the file IPC
    # the worker polls. Never calls run_turn across the boundary.
    def enqueue_turn(session_id:, prompt:)
      require_relative "session_manager"
      Samagotchi::SessionManager.write_turn_input(
        session_id, prompt: prompt, state_dir: @state_dir
      )
    rescue LoadError
      # SessionManager not available (e.g. bridge used standalone in a spec).
      false
    end

    # ── HTTP plumbing ────────────────────────────────────────────────────────

    def read_request(io)
      request_line = io.gets
      return nil if request_line.nil? || request_line.empty?

      method, target, = request_line.split(" ")
      return nil if method.nil? || target.nil?

      headers = {}
      content_length = 0
      while (line = io.gets)
        break if line == "\r\n" || line == "\n"

        key, value = line.split(":", 2)
        next unless key

        headers[key.strip.downcase] = value.to_s.strip
        content_length = value.to_s.to_i if key.strip.downcase == "content-length"
      end

      body = content_length > 0 ? io.read(content_length) : nil
      path, query = split_target(target)
      { method: method, path: path, query: query, headers: headers, body: body }
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    def split_target(target)
      query = nil
      path = target
      if target.include?("?")
        path, query = target.split("?", 2)
      end
      [URI.decode_www_form_component(path), query]
    rescue StandardError
      [target, nil]
    end

    def write_json(io, status, extra_headers, body)
      extra_headers ||= {}
      body ||= {}
      data = JSON.generate(body)
      reason = HTTP_REASONS.fetch(status, "OK")
      headers = {
        "Content-Type" => "application/json",
        "Content-Length" => data.bytesize.to_s,
        "Connection" => "close",
        "Cache-Control" => "no-store",
        "Access-Control-Allow-Origin" => "*"
      }.merge(extra_headers)

      io.write("HTTP/1.1 #{status} #{reason}\r\n")
      headers.each { |k, v| io.write("#{k}: #{v}\r\n") }
      io.write("\r\n")
      io.write(data) unless body.nil? || status == 204
      io.flush
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    # Parse a JSON body defensively; returns nil on failure.
    def parse_json(body)
      return nil if body.nil? || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def fetched(hash, key)
      hash[key] || hash[key.to_sym]
    end

    # Resume cursor for SSE: prefer the browser's native `Last-Event-ID`
    # header (sent automatically on reconnect because we emit `id:` frames),
    # else fall back to the explicit `?from_seq=` query param used by clients
    # that remember their own cursor.
    def reconnect_cursor(headers, query)
      cursor = headers["last-event-id"]
      return cursor if cursor && !cursor.empty?

      return nil unless query

      URI.decode_www_form(query).to_h["from_seq"]
    rescue StandardError
      nil
    end

    def close_after_request?(headers)
      headers["connection"].to_s.downcase == "close"
    end

    def write_sidecar
      record = {
        "port" => @port,
        "bind" => @bind,
        "session_id" => @session_id,
        "started_at" => Time.now.iso8601(3)
      }
      path = File.join(session_dir, SIDECAR_FILE)
      FileUtils.mkdir_p(session_dir)
      temp = "#{path}.tmp"
      File.write(temp, JSON.pretty_generate(record) + "\n")
      File.rename(temp, path)
    rescue StandardError => e
      warn "Bridge: failed to write #{SIDECAR_FILE}: #{e.class}: #{e.message}"
    end

    def session_dir
      Session.session_dir(@session_id, state_dir: @state_dir)
    end

    HTTP_REASONS = {
      200 => "OK",
      202 => "Accepted",
      204 => "No Content",
      400 => "Bad Request",
      404 => "Not Found",
      500 => "Internal Server Error"
    }.freeze
  end
end
