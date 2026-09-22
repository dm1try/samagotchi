# frozen_string_literal: true

require "json"
require "socket"

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

    # POST /session/:id/turn. 202 = queued (body carries the enqueued_id the
    # Bridge also announced in :turn_enqueued).
    # @param client_id [String, nil] identifies the sending UI in the events
    # @return [Response]
    def post_turn(prompt:, client_id: nil)
      post("turn", { session_id: @session_id, prompt: prompt, client_id: client_id }, read_body: true)
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
        begin
          sock = TCPSocket.new(@host, @port)
          break
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError, StandardError
          sock = nil
          sleep(0.15 * (attempt + 1))
        end
      end
      return unless sock

      begin
        lei = last_event_id.to_s.strip
        last_event_line = lei.empty? ? "" : "Last-Event-ID: #{lei}\r\n"
        sock.write("GET /session/#{@session_id}/stream#{query} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nAccept: text/event-stream\r\n#{last_event_line}Connection: keep-alive\r\n\r\n")
        # Skip HTTP headers
        while (line = sock.gets)
          break if line.strip.empty?
        end
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
