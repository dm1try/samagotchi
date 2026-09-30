# frozen_string_literal: true

require "json"
require "socket"

require_relative "worker_sidecar"
require_relative "bridge_client/sse_parser"
require_relative "bridge_client/event_stream"

module Samagotchi
  # Client side of a session worker's Bridge: the 127.0.0.1 HTTP + SSE server
  # each SessionManager worker runs for its Engine (see Bridge). Discovery goes
  # through the worker's `bridge.json` sidecar (WorkerSidecar) in the session
  # directory.
  #
  # Requests are raw one-shot HTTP/1.1 over a TCPSocket (`Connection: close`),
  # exactly what the Bridge's minimal server expects.
  class BridgeClient
    HOST = "127.0.0.1"
    PROBE_TIMEOUT = 0.2
    STREAM_CONNECT_ATTEMPTS = 3
    # Seconds #stream waits for bytes before it asks `running` again.
    STREAM_POLL = 0.5
    # Seconds a one-shot request waits for the whole reply. Every route
    # answers at once (a recap is only asked for); a worker that takes the
    # request and never answers raises Errno::ETIMEDOUT, as a dead one
    # raises Errno::ECONNREFUSED. The event stream has no such limit.
    READ_TIMEOUT = 30
    # Share of the read timeout a request's deadline allows (25 s of 30): the
    # Bridge drops a turn, command, answer or dismissal it reads after the
    # deadline, so one this client timed out on, and said did not go
    # through, never runs when a frozen worker wakes. The rest covers the
    # write and the reply.
    DEADLINE_SHARE = 5 / 6r

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
      port = WorkerSidecar.read(session_dir)&.port
      return nil unless port&.positive?

      # Validate liveness: stale sidecar after worker death causes ECONNREFUSED
      # which surfaces as WEBrick ERROR. Probe quickly and clean up if dead.
      begin
        Socket.tcp(host, port, connect_timeout: PROBE_TIMEOUT).close
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError, IOError, StandardError
        begin
          File.unlink(WorkerSidecar.path(session_dir))
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

    # How often a wait for a new worker's Bridge looks: a missing sidecar is
    # one stat, and a 0.1 s step cost a create up to 0.1 s (the web's
    # create landed on 0.53/0.63/0.73 s).
    SPAWN_POLL_INTERVAL = 0.02

    # Wait for a freshly spawned worker to publish its Bridge.
    # @param timeout [Float] seconds
    # @return [BridgeClient, nil] nil when no live sidecar appeared in time
    def self.wait_for(session_id, session_dir:, timeout:, host: HOST)
      port = poll(timeout, interval: SPAWN_POLL_INTERVAL) { sidecar_port(session_dir, host: host) }
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

    # @param read_timeout [Numeric] see READ_TIMEOUT
    def initialize(session_id:, port:, host: HOST, read_timeout: READ_TIMEOUT)
      @session_id = session_id
      @port = port
      @host = host
      @read_timeout = read_timeout
    end

    # POST /session/:id/answer. 200 = recorded, 409 = another client answered
    # first (or the question is gone), 400 = invalid selection, 408
    # deadline_passed = read too late and dropped (see DEADLINE_SHARE).
    # @return [Response]
    def answer(id:, selected:, freeform: nil)
      post("answer", { id: id, selected: selected, freeform: freeform, deadline: deadline }, read_body: true)
    end

    # POST /session/:id/question/dismiss: leave the question unanswered.
    # 200 = dismissed, 409 = no longer pending (answered, cancelled, or
    # another question), 404 = a worker older than the route, 408 = too late.
    # @return [Response]
    def dismiss_question(id:)
      post("question/dismiss", { id: id, deadline: deadline }, read_body: true)
    end

    # POST /session/:id/turn. 202 = queued (body carries the enqueued_id the
    # Bridge also announced in :turn_enqueued), 408 deadline_passed = the
    # Bridge read it too late and dropped it (see DEADLINE_SHARE).
    # @param client_id [String, nil] identifies the sending UI in the events
    # @return [Response]
    # @param no_interrupt [Boolean] run the turn with the raised iteration limit
    # @param images [Array<Hash>] refs ({file:, name:}) to images already in
    #   the session's images/
    def post_turn(prompt:, client_id: nil, no_interrupt: false, images: nil)
      body = { session_id: @session_id, prompt: prompt, client_id: client_id }
      body[:no_interrupt] = true if no_interrupt
      body[:images] = images if images && !images.empty?
      body[:deadline] = deadline
      post("turn", body, read_body: true)
    end

    # POST /session/:id/command: a session command (/model, /models,
    # !rollback, !cmd, /continue) for the worker to run. 202 = queued (body
    # carries the command_id its :command_ran will name), 400 = not a
    # command, 404 = a worker older than the route, 408 = too late.
    # @param card [Boolean] the line is a card's action: its command_queued
    #   and command_ran carry card: true, and the UIs show no echo of it
    # @return [Response]
    def post_command(line:, client_id: nil, card: false)
      payload = { line: line, client_id: client_id, deadline: deadline }
      payload[:card] = true if card
      post("command", payload, read_body: true)
    end

    # POST /session/:id/exit: ask the worker to exit now. 200 = it will
    # (status "exiting"), 409 = something keeps it up (reason), 404 with
    # error "not_found" = a worker older than the route.
    # @param client_id [String] the asking UI, whose own streams don't hold
    # @return [Response]
    def request_exit(client_id:, delete: false)
      body = { client_id: client_id }
      body[:delete] = true if delete
      post("exit", body, read_body: true)
    end

    # POST /session/:id/recap: the saved recap, and a new one asked for.
    # @return [Response] 200 {enabled, saved, request, min_user_turns}
    def request_recap
      post("recap", {}, read_body: true)
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
      response = read_reply(sock, path)
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
    # @param running [#call, nil] asked before every read, and every
    #   STREAM_POLL seconds of silence: the stream ends once it returns
    #   false. A quiet stream is never cut otherwise.
    def stream(query: "", last_event_id: nil, running: nil)
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
          if running
            break unless running.call
            next unless sock.wait_readable(STREAM_POLL)
          end
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

    # When this client stops waiting for a reply, as epoch seconds (see
    # DEADLINE_SHARE). Wall clock: the worker runs on this machine and reads
    # the same one.
    def deadline = (Time.now.to_f + (@read_timeout * DEADLINE_SHARE)).round(3)

    def post(path, payload, read_body:)
      sock = TCPSocket.new(@host, @port)
      json_body = JSON.generate(payload)
      sock.write("POST /session/#{@session_id}/#{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nContent-Type: application/json\r\nContent-Length: #{json_body.bytesize}\r\nConnection: close\r\n\r\n#{json_body}")
      reply = read_reply(sock, path, whole: read_body)
      body = read_body ? reply.split("\r\n\r\n", 2)[1] : nil
      Response.new(status: reply[/\AHTTP\/1\.[01] (\d{3})/, 1].to_i, body: body)
    ensure
      sock&.close rescue nil
    end

    # The reply up to the Bridge's close (or its first line only), within
    # @read_timeout in all.
    # @raise [Errno::ETIMEDOUT]
    def read_reply(sock, path, whole: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
      reply = +""
      loop do
        break if !whole && reply.include?("\n")

        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless left.positive? && sock.wait_readable(left)
          raise Errno::ETIMEDOUT, "bridge #{path}: no reply within #{@read_timeout}s"
        end

        reply << sock.readpartial(16_384)
      rescue EOFError
        break
      end
      reply.force_encoding(Encoding::UTF_8)
    end
  end
end
