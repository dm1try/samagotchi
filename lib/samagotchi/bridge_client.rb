# frozen_string_literal: true

require "digest"
require "json"
require_relative "verify_anchor"
require "socket"

require_relative "worker_sidecar"
require_relative "bridge_secret"
require_relative "delivery"
require_relative "chi_invocation"
require_relative "bridge_client/stream_open"
require_relative "bridge_client/sse_parser"
require_relative "bridge_client/event_stream"
require_relative "bridge_client/stream_request"

module Samagotchi
  # Client side of a session worker's Bridge: the 127.0.0.1 HTTP + SSE server
  # each SessionManager worker runs for its Engine (see Bridge). Discovery goes
  # through WorkerLink (the worker's `bridge.json` sidecar, WorkerSidecar, in
  # the session directory); .for_sidecar makes the client.
  #
  # Requests are raw one-shot HTTP/1.1 over a TCPSocket (`Connection: close`),
  # exactly what the Bridge's minimal server expects.
  class BridgeClient
    HOST = "127.0.0.1"
    # A reply's status line; its code is group 1.
    STATUS_LINE = StreamRequest::STATUS_LINE
    # The request header that carries the Bridge's secret (Bridge#secret_ok?).
    SECRET_HEADER = BridgeSecret::HEADER
    STREAM_CONNECT_ATTEMPTS = 3
    # Seconds #open_stream waits for the Bridge's response headers:
    # a worker that took the connection and froze must not hold the web's
    # proxy thread (as EventStream::HEADER_TIMEOUT for the TUI's).
    STREAM_HEADER_TIMEOUT = 5.0
    # Seconds #stream waits for bytes before it asks `running` again.
    STREAM_POLL = 0.5
    # Seconds a one-shot request waits for the whole reply. Every route
    # answers at once (a recap is only asked for); a worker that takes the
    # request and never answers raises Errno::ETIMEDOUT, as a dead one
    # raises Errno::ECONNREFUSED. The event stream has no such limit.
    READ_TIMEOUT = 30
    # Share of the read timeout a request's deadline allows (25 s of 30): the
    # Bridge drops a turn, command, answer, dismissal or exit it reads after the
    # deadline, so one this client timed out on, and said did not go
    # through, never runs when a frozen worker wakes. The rest covers the
    # write and the reply.
    DEADLINE_SHARE = 5 / 6r

    # A Bridge reply: HTTP status code and raw body (nil when not read).
    Response = Struct.new(:status, :body, keyword_init: true) do
      def ok? = status == 200

      # The Bridge refused it for want of its secret (BridgeSecret.refused says what to do).
      def secret_refused? = BridgeSecret.refused?(status, body)

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
    # @param via [ChiInvocation] how the commands are spelled (chi --remote
    #   NAME: no --resume there, a message starts the fresh worker)
    def self.stale_worker_message(session_id, cant:, via: ChiInvocation::HERE)
      stop = via.command("sessions stop #{session_id}")
      restart = if via.remote?
                  "#{stop}, then a message (#{via.command("send #{session_id} -m …")}) starts a fresh one"
                else
                  "#{stop} && chi --resume #{session_id}"
                end
      "this session's worker runs an older chi and can't #{cant}; restart it: #{restart} (its turns still work)"
    end

    # The one way a client is made for a worker: its port and its secret
    # come from the same sidecar read, so a respawned worker (a new port, a
    # new secret) is reached by a client made after it, never by hand.
    # @param sidecar [WorkerSidecar, nil]
    # @return [BridgeClient, nil] nil without a sidecar
    def self.for_sidecar(session_id, sidecar, host: HOST, read_timeout: READ_TIMEOUT)
      return nil unless sidecar

      new(session_id: session_id, port: sidecar.port, secret: sidecar.secret, host: host, read_timeout: read_timeout)
    end

    # How often a wait for a new worker's Bridge looks: a missing sidecar is
    # one stat, and a 0.1 s step cost a create up to 0.1 s (the web's
    # create landed on 0.53/0.63/0.73 s).
    SPAWN_POLL_INTERVAL = 0.02

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

    # Which worker this client talks to, for EventStream: a rediscovered
    # client with another key is a new worker. A Bridge's port, and a
    # fingerprint of its secret when it has one: a new worker that got the
    # old one's port back has another secret, so it is still a new worker.
    def worker_key = @secret ? "#{@port}-#{Digest::SHA256.hexdigest(@secret)[0, 12]}" : @port

    # @param secret [String, nil] the Bridge's secret, sent in SECRET_HEADER
    #   with every request (nil: a worker from before secrets, which asks for
    #   none); from the worker's sidecar (.for_sidecar), never typed
    # @param read_timeout [Numeric] see READ_TIMEOUT
    def initialize(session_id:, port:, secret:, host: HOST, read_timeout: READ_TIMEOUT)
      @session_id = session_id
      @port = port
      @secret = secret
      @host = host
      @read_timeout = read_timeout
    end

    # The secret never shows in an inspect (a log line, an error's message).
    def inspect = "#<#{self.class.name} session_id=#{@session_id.inspect} port=#{@port}>"
    alias to_s inspect

    # POST /session/:id/answer. 200 = recorded, 409 = another client answered
    # first (or the question is gone), 400 = invalid selection, 408
    # deadline_passed = read too late and dropped (see DEADLINE_SHARE), 403
    # parent_answer_refused (with its reason) = a parent's pick (client_id
    # cli:answer) beyond the worker's guardrails.parent_answers.
    # @param client_id [String, nil] who answers (chi answer marks its own)
    # @return [Response]
    def answer(id:, selected:, freeform: nil, client_id: nil)
      body = { id: id, selected: selected, freeform: freeform, deadline: deadline }
      body[:client_id] = client_id if client_id
      post("answer", body, read_body: true)
    end

    # POST /session/:id/question/dismiss: leave the question unanswered.
    # 200 = dismissed, 409 = no longer pending (answered, cancelled, or
    # another question), 404 = a worker older than the route, 408 = too late.
    # @return [Response]
    def dismiss_question(id:)
      post("question/dismiss", { id: id, deadline: deadline }, read_body: true)
    end

    # POST /session/:id/guardrails/wrong: mark this session's System 1
    # auto-allow as one it should have asked about; 404 when unknown.
    # @return [Response]
    def mark_system_one_wrong(judgment_id:)
      post("guardrails/wrong", { id: judgment_id }, read_body: true)
    end

    # POST /session/:id/turn/dequeue: take back a queued message (one that
    # waits for the running turn's end) before it runs. 200 {status:
    # "removed", enqueued_id, prompt}; 409 already_started (a turn took
    # it) or not_queued (a next-step message); 404 unknown_enqueued_id; a
    # 404 not_found: a worker older than the route (its sidecar lacks
    # "unqueue"); 408 = too late.
    # @param client_id [String, nil] the removing UI, in its :turn_dequeued
    # @return [Response]
    def dequeue(enqueued_id:, client_id: nil)
      post("turn/dequeue", { enqueued_id: enqueued_id, client_id: client_id, deadline: deadline }, read_body: true)
    end

    # POST /session/:id/turn. 202 = queued (body carries the enqueued_id the
    # Bridge also announced in :turn_enqueued), 408 deadline_passed = the
    # Bridge read it too late and dropped it (see DEADLINE_SHARE).
    # @param client_id [String, nil] identifies the sending UI in the events
    # @return [Response]
    # @param no_interrupt [Boolean] run the turn with the raised iteration limit
    # @param images [Array<Hash>] refs ({file:, name:}) to images already in
    #   the session's images/
    # @param author [String, nil] who wrote it when it isn't the session's
    #   owner; sent only when given (SessionManager.deliver_turn)
    # @param pending_limit [Integer, nil] with a participant's +author+: how
    #   many of their turns may be running or waiting (429 too_many_turns past it)
    def post_turn(prompt:, client_id: nil, no_interrupt: false, images: nil, delivery: nil, author: nil, pending_limit: nil,
                  verify: nil)
      body = { session_id: @session_id, prompt: prompt, client_id: client_id }
      body[:no_interrupt] = true if no_interrupt
      body[:author] = author if author
      body[:pending_limit] = pending_limit if author && pending_limit
      body[:images] = images if images && !images.empty?
      body[:delivery] = delivery unless delivery.nil? || Delivery.next_step?(delivery)
      anchor = VerifyAnchor.from(verify)
      body[:verify] = anchor.to_file if anchor
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

    # POST /session/:id/exit: ask the worker to exit now (+restart+: hand
    # the session to a new worker, a worker with the "restart" feature). 200
    # = it will (status "exiting"/"restarting"), 409 = something keeps it up (reason), 404 with
    # error "not_found" = a worker older than the route, 408 = too late.
    # @param client_id [String] the asking UI, whose own streams don't hold
    # @return [Response]
    def request_exit(client_id:, delete: false, restart: false, stop: false, ask: true)
      body = { client_id: client_id }
      body[:delete] = true if delete
      body[:restart] = true if restart
      body[:stop] = "all" if stop
      body[:ask] = false unless ask
      body[:deadline] = deadline
      post("exit", body, read_body: true)
    end

    # POST /session/:id/recap: the saved recap, and a new one asked for.
    # @return [Response] 200 {enabled, saved, request, min_user_turns}
    def request_recap
      post("recap", {}, read_body: true)
    end

    # POST /session/:id/cancel. 202 = requested (body names the reason the
    # Bridge took), 409 = no active turn.
    # @return [Response]
    def cancel(reason:)
      post("cancel", { reason: reason }, read_body: true)
    end

    # POST /session/:id/tasks/stop: stop a background task this session's
    # conversation created, as the user (Bridge#handle_task_stop). 200 with
    # its final status, 404 task_not_found, 409 not_running. Synchronous:
    # the worker answers once the task is gone (up to its 3 s grace).
    # @return [Response]
    def stop_task(task_id)
      post("tasks/stop", { task_id: task_id }, read_body: true)
    end

    # POST /session/:id/holds/stop: stop everything this worker's user can
    # stop (its reminders, the background tasks a finish wake watches that
    # still run, its delegate children) without the worker exiting
    # (Bridge#handle_holds_stop). 200 {status: "stopped", stopped:
    # {reminders:, tasks:, delegates:}}; 501 for a worker without the route.
    # @return [Response]
    def stop_holds
      post("holds/stop", {}, read_body: true)
    end

    # How long the approval relay's calls wait for a reply: a parent's Stop
    # isn't held for READ_TIMEOUT by a child that doesn't answer.
    RELAY_TIMEOUT = 5
    # How long a child waits for its parent's word on a relay (#relay_status).
    RELAY_STATUS_TIMEOUT = 2

    # POST /session/:id/relay on a child's worker: a parent's relay of the
    # child's approval opened, closed or was answered (the child asks the
    # parent which answer, #relay_status). 200 answered, 409 no longer
    # pending, 403 refused (a parent agent's allow), 422 relay_unverified.
    # @param action [String] "opened", "closed" or "answered"
    # @return [Response]
    # @raise [SystemCallError] the worker is gone or didn't answer in time
    def relay(action:, relay_id:, question_id:, read_timeout: RELAY_TIMEOUT, **extra)
      post("relay", { action: action, relay_id: relay_id, question_id: question_id, **extra },
           read_body: true, read_timeout: read_timeout)
    end

    # POST /session/:id/relay/status on a parent's worker: what its relay
    # +relay_id+ holds (child_id, child_question_id, state, answer, by); 404
    # for one it doesn't know. A POST with a body: routes match exact paths.
    # @return [Response]
    # @raise [SystemCallError]
    def relay_status(relay_id, read_timeout: RELAY_STATUS_TIMEOUT)
      post("relay/status", { relay_id: relay_id }, read_body: true, read_timeout: read_timeout)
    end

    # GET /session/:id/<path> as JSON.
    # @return [Hash, nil] the parsed body, or nil unless the Bridge answered 200
    def get_json(path)
      status, body = get(path)
      status == 200 ? body : nil
    end

    # GET /session/:id/<path>, telling a refusal apart from no answer: an
    # older worker's 404 for a route it lacks from a refused connect, a
    # timeout or a 500.
    # @return [Array(Integer, Object)] the status and the parsed JSON body
    #   (nil when it isn't JSON); [nil, nil] when no reply came
    def get(path)
      response = get_response(path)
      [response.status, response.json]
    rescue StandardError
      [nil, nil]
    end

    # GET /session/:id/<path>, preserving the raw response and raising on I/O.
    # @return [Response]
    def get_response(path)
      sock = TCPSocket.new(@host, @port)
      sock.write("GET /session/#{@session_id}/#{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\n#{secret_line}Connection: close\r\n\r\n")
      response = read_reply(sock, path)
      # A 500 whose text has "200" in it is not a 200.
      status = response && response[STATUS_LINE, 1]
      raise IOError, "bridge #{path}: invalid response status" unless status

      body = response.split("\r\n\r\n", 2)[1] || ""
      Response.new(status: status.to_i, body: body)
    ensure
      sock&.close rescue nil
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

    # Open GET /session/:id/stream and classify the response before the
    # caller answers its own request.
    # @param header_timeout [Float] see STREAM_HEADER_TIMEOUT
    # @param attempts [Integer] retries for connection failures only
    # @yield [sock] called after response headers arrive, before classifying a
    #   refusal; EventStream uses it to publish the socket for #close
    # @return [StreamOpen::Opened, StreamOpen::Refused, StreamOpen::Unreachable]
    def open_stream(query: "", last_event_id: nil, header_timeout: STREAM_HEADER_TIMEOUT,
                    attempts: STREAM_CONNECT_ATTEMPTS)
      count = 0
      while count < attempts
        count += 1
        connection = connect_stream(query: query, last_event_id: last_event_id, timeout: header_timeout)
        if connection
          sock, status, headers = connection
          unless !block_given? || yield(sock)
            sock.close rescue nil
            return StreamOpen::Unreachable.new(attempts: count)
          end
          return StreamOpen.classify(sock, status, headers)
        end
        sleep(0.15 * count) if count < attempts
      end
      StreamOpen::Unreachable.new(attempts: count)
    rescue Errno::ETIMEDOUT
      StreamOpen::Unreachable.new(attempts: [count, 1].max)
    rescue SystemCallError, SocketError, IOError
      StreamOpen::Unreachable.new(attempts: [count, 1].max)
    end

    # Read a successful stream opened by #open_stream.
    # @param opened [StreamOpen::Opened]
    # @param running [#call, nil] checked before every read and every
    #   STREAM_POLL seconds of silence
    def read_stream(opened, running: nil)
      sock = opened.sock
      begin
        loop do
          if running
            break unless running.call
            next unless sock.wait_readable(STREAM_POLL)
          end
          yield sock.readpartial(4096)
        rescue IOError, Errno::ECONNRESET, Errno::ECONNREFUSED # EOFError is an IOError
          break
        end
      ensure
        sock&.close rescue nil
      end
    end

    # Follow the session's events on a reader thread (see EventStream).
    # @param snapshot [Boolean] join with a snapshot frame
    # @param client_id [String, nil] names the stream (see EventStream)
    # @param rediscover [#call, nil] follows a new worker (see EventStream)
    # @yieldparam event [Hash] string-keyed event
    # @return [EventStream] started
    def follow(snapshot: true, client_id: nil, reconnect_delays: EventStream::DEFAULT_RECONNECT_DELAYS, rediscover: nil,
               &on_event)
      EventStream.new(self, snapshot: snapshot, client_id: client_id, reconnect_delays: reconnect_delays,
                            rediscover: rediscover, &on_event).start
    end

    # Open GET /session/:id/stream and read past the response headers.
    # @param timeout [Float, nil] give up when the headers aren't all in by then
    # @return [Array(TCPSocket, Integer, Hash), nil] the socket positioned
    #   at the body, the HTTP status and the headers (StreamRequest.open), or
    #   nil when the Bridge can't be reached
    def connect_stream(query: "", last_event_id: nil, timeout: nil)
      StreamRequest.open(host: @host, port: @port, path: "/session/#{@session_id}/stream#{query}",
                         last_event_id: last_event_id, headers: secret_headers, timeout: timeout)
    end

    private

    # The request header naming the Bridge's secret (none without one).
    def secret_headers = @secret ? { SECRET_HEADER => @secret } : {}

    def secret_line = secret_headers.map { |name, value| "#{name}: #{value}\r\n" }.join

    # When this client stops waiting for a reply, as epoch seconds (see
    # DEADLINE_SHARE). Wall clock: the worker runs on this machine and reads
    # the same one.
    def deadline = (Time.now.to_f + (@read_timeout * DEADLINE_SHARE)).round(3)

    def post(path, payload, read_body:, read_timeout: @read_timeout)
      sock = TCPSocket.new(@host, @port)
      json_body = JSON.generate(payload)
      sock.write("POST /session/#{@session_id}/#{path} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\n#{secret_line}Content-Type: application/json\r\nContent-Length: #{json_body.bytesize}\r\nConnection: close\r\n\r\n#{json_body}")
      reply = read_reply(sock, path, whole: read_body, timeout: read_timeout)
      body = read_body ? reply.split("\r\n\r\n", 2)[1] : nil
      Response.new(status: reply[STATUS_LINE, 1].to_i, body: body)
    ensure
      sock&.close rescue nil
    end

    # The reply up to the Bridge's close (or its first line only), within
    # +timeout+ seconds in all (@read_timeout by default).
    # @raise [Errno::ETIMEDOUT]
    def read_reply(sock, path, whole: true, timeout: @read_timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      reply = +""
      loop do
        break if !whole && reply.include?("\n")

        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        unless left.positive? && sock.wait_readable(left)
          raise Errno::ETIMEDOUT, "bridge #{path}: no reply within #{timeout}s"
        end

        reply << sock.readpartial(16_384)
      rescue EOFError
        break
      end
      reply.force_encoding(Encoding::UTF_8)
    end
  end
end
