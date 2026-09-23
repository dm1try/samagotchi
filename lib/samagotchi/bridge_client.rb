# frozen_string_literal: true

require "json"
require "socket"

require_relative "bridge_client/sse_parser"
require_relative "bridge_client/event_stream"

module Samagotchi
  # Client side of a session worker's Bridge: the 127.0.0.1 HTTP + SSE server
  # each SessionManager worker runs for its Engine (see Bridge). Discovery goes
  # through the worker's `bridge.json` sidecar in the session directory.
  #
  # Requests are raw one-shot HTTP/1.1 over a TCPSocket (`Connection: close`),
  # exactly what the Bridge's minimal server expects.
  class BridgeClient
    HOST = "127.0.0.1"
    SIDECAR_FILE = "bridge.json"
    PROBE_TIMEOUT = 0.2
    STREAM_CONNECT_ATTEMPTS = 3

    # A Bridge reply: HTTP status code and raw body (nil when not read).
    Response = Struct.new(:status, :body, keyword_init: true) do
      def ok? = status == 200

      # @return [Hash, nil] the body parsed as JSON, or nil when it is not
      def json
        JSON.parse(body.to_s)
      rescue JSON::ParserError
        nil
      end
    end

    # What a UI says when the Bridge answers a route with 404: the worker runs
    # code from before the route. Restarting it picks up the installed chi.
    # @param cant [String] what the old worker can't do, e.g. "run commands"
    def self.stale_worker_message(session_id, cant:)
      "this session's worker runs an older chi and can't #{cant}; " \
        "restart it: chi sessions stop #{session_id} && chi --resume #{session_id} (its turns still work)"
    end

    # Port of the live Bridge advertised in +session_dir+'s sidecar, or nil.
    # A sidecar whose port refuses a quick connect is stale (its worker died)
    # and is removed.
    # @param session_dir [String]
    # @return [Integer, nil]
    def self.sidecar_port(session_dir, host: HOST)
      sidecar = File.join(session_dir, SIDECAR_FILE)
      return nil unless File.file?(sidecar)

      data = JSON.parse(File.read(sidecar))
      port = data["port"]
      port = port.is_a?(Integer) ? port : port.to_i
      return nil unless port.to_i > 0

      # Validate liveness: stale sidecar after worker death causes ECONNREFUSED
      # which surfaces as WEBrick ERROR. Probe quickly and clean up if dead.
      begin
        Socket.tcp(host, port, connect_timeout: PROBE_TIMEOUT).close
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError, IOError, StandardError
        begin
          File.unlink(sidecar)
        rescue StandardError
          nil
        end
        return nil
      end
      port
    rescue StandardError
      nil
    end

    # @return [BridgeClient, nil] a client for the live Bridge in +session_dir+
    def self.discover(session_id, session_dir:, host: HOST)
      port = sidecar_port(session_dir, host: host)
      port && new(session_id: session_id, port: port, host: host)
    end

    # Wait for a freshly spawned worker to publish its Bridge.
    # @param timeout [Float] seconds
    # @return [BridgeClient, nil] nil when no live sidecar appeared in time
    def self.wait_for(session_id, session_dir:, timeout:, host: HOST)
      port = poll(timeout) { sidecar_port(session_dir, host: host) }
      port && new(session_id: session_id, port: port, host: host)
    end

    # Call the block every +interval+ seconds until it returns a truthy value
    # or +timeout+ seconds have passed (it is always called at least once).
    # @return [Object, nil] the block's first truthy value
    def self.poll(timeout, interval: 0.1)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      loop do
        value = yield
        return value if value
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(interval)
      end
    end

    attr_reader :session_id, :port, :host

    def initialize(session_id:, port:, host: HOST)
      @session_id = session_id
      @port = port
      @host = host
    end

    # POST /session/:id/answer. 200 = recorded, 409 = another client answered
    # first (or the question is gone), 400 = invalid selection.
    # @return [Response]
    def answer(id:, selected:, freeform: nil)
      post("answer", { id: id, selected: selected, freeform: freeform }, read_body: true)
    end

    # POST /session/:id/question/dismiss: leave the question unanswered.
    # 200 = dismissed, 409 = no longer pending (answered, cancelled, or
    # another question), 404 = a worker older than the route.
    # @return [Response]
    def dismiss_question(id:)
      post("question/dismiss", { id: id }, read_body: true)
    end

    # POST /session/:id/turn. 202 = queued (body carries the enqueued_id the
    # Bridge also announced in :turn_enqueued).
    # @param client_id [String, nil] identifies the sending UI in the events
    # @return [Response]
    # @param no_interrupt [Boolean] run the turn with the raised iteration limit
    def post_turn(prompt:, client_id: nil, no_interrupt: false)
      body = { session_id: @session_id, prompt: prompt, client_id: client_id }
      body[:no_interrupt] = true if no_interrupt
      post("turn", body, read_body: true)
    end

    # POST /session/:id/command: a session command (/model, /models,
    # !rollback, !cmd, /continue) for the worker to run. 202 = queued (body
    # carries the command_id its :command_ran will name), 400 = not a
    # command, 404 = a worker older than the route.
    # @return [Response]
    def post_command(line:, client_id: nil)
      post("command", { line: line, client_id: client_id }, read_body: true)
    end

    # POST /session/:id/exit: ask the worker to exit now. 200 = it will
    # (status "exiting"), 409 = something keeps it up (reason), 404 with
    # error "not_found" = a worker older than the route.
    # @param client_id [String] the asking UI, whose own streams don't hold
    # @return [Response]
    def request_exit(client_id:)
      post("exit", { client_id: client_id }, read_body: true)
    end

    # POST /session/:id/cancel. 202 = requested, 409 = no active turn.
    # @return [Response] (status only)
    def cancel(reason:)
      post("cancel", { reason: reason }, read_body: false)
    end

    # GET /session/:id/<path> as JSON.
    # @return [Hash, nil] the parsed body, or nil unless the Bridge answered 200
    def get_json(path)
      sock = TCPSocket.new(@host, @port)
      sock.write("GET /session/#{@session_id}/#{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nConnection: close\r\n\r\n")
      response = sock.read
      sock.close rescue nil
      return nil unless response

      status_line = response.lines.first.to_s
      return nil unless status_line.include?("200")

      body = response.split("\r\n\r\n", 2)[1] || ""
      JSON.parse(body)
    rescue StandardError
      nil
    end

    # Monotonic SSE cursor of the live Engine, from GET /session/:id/state.
    # @return [Integer, nil]
    def event_seq
      state = get_json("state")
      seq = state && state.dig("session_state_snapshot", "event_seq")
      seq.nil? ? nil : seq.to_i
    rescue StandardError
      nil
    end

    # GET /session/:id/stream: yield the raw SSE body bytes as they arrive
    # until the Bridge closes the stream.
    # @param query [String] "" or "?from_seq=N"
    # @param last_event_id [String, nil] reconnect cursor; the Bridge prefers it
    #   over ?from_seq
    def stream(query: "", last_event_id: nil)
      sock = nil
      # Absorb the probe→connect race around a resumed worker's bridge:
      # the sidecar probe can succeed a moment before the worker dies (or
      # the bridge socket briefly refuses). A few quick bounded retries
      # avoid the silent empty-200 that EventSource would otherwise keep
      # re-opening.
      STREAM_CONNECT_ATTEMPTS.times do |attempt|
        sock, = connect_stream(query: query, last_event_id: last_event_id)
        break if sock

        sleep(0.15 * (attempt + 1))
      end
      return unless sock

      begin
        loop do
          chunk = sock.readpartial(4096)
          yield chunk
        rescue EOFError, IOError, Errno::ECONNRESET, Errno::ECONNREFUSED
          break
        end
      ensure
        sock&.close rescue nil
      end
    end

    # Follow the session's events on a reader thread (see EventStream).
    # @param snapshot [Boolean] join with a snapshot frame
    # @param client_id [String, nil] names the stream (see EventStream)
    # @yieldparam event [Hash] string-keyed event
    # @return [EventStream] started
    def follow(snapshot: true, client_id: nil, reconnect_delays: EventStream::DEFAULT_RECONNECT_DELAYS, &on_event)
      EventStream.new(self, snapshot: snapshot, client_id: client_id, reconnect_delays: reconnect_delays,
                            &on_event).start
    end

    # Open GET /session/:id/stream and read past the response headers.
    # @param timeout [Float, nil] give up when the headers don't start in time
    # @return [Array(TCPSocket, Integer), nil] the socket positioned at the
    #   body and the HTTP status, or nil when the Bridge can't be reached
    def connect_stream(query: "", last_event_id: nil, timeout: nil)
      sock = TCPSocket.new(@host, @port)
      lei = last_event_id.to_s.strip
      last_event_line = lei.empty? ? "" : "Last-Event-ID: #{lei}\r\n"
      sock.write("GET /session/#{@session_id}/stream#{query} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nAccept: text/event-stream\r\n#{last_event_line}Connection: keep-alive\r\n\r\n")
      raise Errno::ETIMEDOUT if timeout && !sock.wait_readable(timeout)

      status = sock.gets.to_s[/\AHTTP\/1\.[01] (\d{3})/, 1].to_i
      while (line = sock.gets)
        break if line.strip.empty?
      end
      [sock, status]
    rescue SystemCallError, SocketError, IOError
      sock&.close rescue nil
      nil
    end

    private

    def post(path, payload, read_body:)
      sock = TCPSocket.new(@host, @port)
      json_body = JSON.generate(payload)
      sock.write("POST /session/#{@session_id}/#{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nContent-Type: application/json\r\nContent-Length: #{json_body.bytesize}\r\nConnection: close\r\n\r\n#{json_body}")
      status_line = sock.gets
      body = read_body ? sock.read.to_s.split("\r\n\r\n", 2)[1] : nil
      Response.new(status: status_line.to_s[/\AHTTP\/1\.[01] (\d{3})/, 1].to_i, body: body)
    ensure
      sock&.close rescue nil
    end
  end
end
