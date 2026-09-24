# frozen_string_literal: true

require "socket"
require "json"
require "uri"
require "fileutils"
require "securerandom"
require "time"

require_relative "bridge/bounded_queue"
require_relative "bridge/event_id"
require_relative "bridge/ring_buffer"
require_relative "bridge/sse_writer"
require_relative "bridge/turn_accumulator"
require_relative "session"
require_relative "engine"
require_relative "session_commands"
require_relative "image_store"

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
    # Cancel reasons a client may name (the web sends user, an attached TUI
    # ctrl_c); anything else is :manual, so client input never mints symbols.
    CANCEL_REASONS = %w[manual user ctrl_c].freeze
    # How long #stop waits for requests it is answering (not open streams).
    REQUEST_GRACE_SECONDS = 1.0
    # The largest request body read (images travel as refs, never bytes).
    MAX_BODY_BYTES = 1_000_000
    MAX_TURN_IMAGES = 20

    # @param engine [Samagotchi::Engine] the owning engine (must already live
    #   in this process)
    # @param state_dir [String] the session state directory root
    # @param session_id [String] this bridge's session id
    # @param bind [String] bind address (127.0.0.1 only)
    # @param port [Integer] port to bind (0 → OS-assigned, read back)
    # @param ring_capacity [Integer] shared ring-buffer capacity
    # @param heartbeat_interval [Float] idle `: ping` seconds
    # @param input_format [Integer, nil] the input-file format the owning
    #   worker reads, advertised in the sidecar for writers (see
    #   SessionManager.write_turn_input); nil advertises none (plain text)
    # @param on_input [#call, nil] called once a turn for this session is
    #   queued, to wake the worker loop (Worker::Waker#wake)
    # @param on_command [#call, nil] takes a session command
    #   ({command_id:, client_id:, line:}) for the worker loop to run; without
    #   one, POST /command answers 501
    # @param on_exit_request [#call, nil] a client asks the worker to exit
    #   now: takes the client_id and delete: (the exit is to delete the
    #   session, /exit --delete), returns nil when the worker will leave or
    #   the Symbol that keeps it up (WorkerIdleExit#hold_for_request); called
    #   with the event log held. Without one, POST /exit answers 501
    # @param exit_discards [#call, nil] after an exit the worker agreed to:
    #   whether it will delete the session as empty (the 200 says
    #   +discard+); without one the reply leaves the field out
    def initialize(engine:, state_dir:, session_id:, bind: DEFAULT_BIND,
                   port: 0, ring_capacity: DEFAULT_RING_CAPACITY,
                   heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL, input_format: nil, on_input: nil,
                   on_command: nil, on_exit_request: nil, exit_discards: nil)
      @engine = engine
      @on_input = on_input
      @on_command = on_command
      @on_exit_request = on_exit_request
      @exit_discards = exit_discards
      @input_format = input_format
      @state_dir = state_dir
      @session_id = session_id
      @bind = bind
      @port = port
      @ring = RingBuffer.new(capacity: ring_capacity)
      @accumulator = TurnAccumulator.new
      @heartbeat_interval = heartbeat_interval
      @epoch = SecureRandom.hex(4)

      @capture_handle = nil
      @server = nil
      @accept_thread = nil
      @connection_threads = []
      @stopped = false
      @mutex = Monitor.new
      @open_streams = 0
      # Open streams by the client_id a stream named (`?client_id=`); web
      # tabs, through the `chi web` proxy, name none.
      @streams_by_client = Hash.new(0)
      @last_client_activity_at = monotonic_now
    end

    # @return [Boolean] whether the server has been stopped.
    def stopped?
      @mutex.synchronize { @stopped }
    end

    # This worker's epoch: event_seq starts over in each worker, so every
    # event id and snapshot carries it (see EventId).
    # @return [String]
    attr_reader :epoch

    # @return [Integer] SSE streams open now: one per attached TUI or web tab
    def open_streams
      @mutex.synchronize { @open_streams }
    end

    # Streams held by anyone but +client_id+: a client's own stream (or two,
    # while it reconnects and the old one isn't noticed dead yet) doesn't
    # count. A closed stream counts until its next write fails (heartbeat).
    # @return [Integer]
    def open_streams_except(client_id)
      @mutex.synchronize { @open_streams - (client_id ? @streams_by_client[client_id] : 0) }
    end

    # Monotonic time of the last request, stream open or stream close. The
    # worker's idle exit counts from it. A connect that sends no request (the
    # sidecar liveness probe) doesn't count.
    # @return [Float]
    def last_client_activity_at
      @mutex.synchronize { @last_client_activity_at }
    end

    # Bind the listen socket (OS-assigned when port == 0), register the shared
    # capture observer, start the acceptor thread, and write the port sidecar.
    # Non-blocking: returns once the socket is listening.
    # @return [self]
    def start
      @server = TCPServer.new(@bind, @port)
      @port = @server.local_address.ip_port
      @capture_handle = @engine.subscribe(observer: capture_observer)
      @accumulator_handle = @engine.subscribe(observer: @accumulator)
      @accept_thread = Thread.new { accept_loop }
      @accept_thread.report_on_exception = false
      write_sidecar
      self
    rescue StandardError => e
      stop
      raise e
    end

    # Stop the acceptor, release the socket and remove the sidecar, so clients
    # don't have to find it stale. Does not stop the owning turn. Joins the
    # acceptor thread so the process can exit cleanly (Ruby waits for a thread
    # blocked in IO.select at VM shutdown). Safe to call again.
    def stop
      @mutex.synchronize { @stopped = true }
      begin
        @server&.close
      rescue StandardError
        nil
      end
      @capture_handle&.unsubscribe
      @accumulator_handle&.unsubscribe
      # A turn post killed between its enqueue and its reply looks failed to
      # the web, which then queues the prompt again from the input file.
      await_answers(REQUEST_GRACE_SECONDS)
      @connection_threads.each { |t| t.kill rescue nil }
      @connection_threads.clear
      @accept_thread&.join(2)
      remove_sidecar
      nil
    end

    # What a joining client needs to render the session now, consistent with
    # the event log: the Engine's messages (not the lagging copy on disk),
    # the turn in progress, turns queued behind it, the idle recap since the
    # last turn, the recap saved with the session (also from before the last
    # turns: {text:, covered:, turns_since:, created_at:}), a pending continue offer, the guardrail load warning, and the
    # event_seq it all covers.
    # Taken with the log held, so no event is half-applied.
    # @return [Hash] {messages:, current_turn:, queued:, recap:, saved_recap:, continue_offer:, guardrail_warning:, event_seq:, event_id:}
    def snapshot
      @engine.synchronize_events do
        seq = @engine.event_count
        {
          messages: @engine.messages_checkpoint,
          current_turn: @accumulator.current_turn,
          queued: @accumulator.queued,
          recap: @accumulator.recap,
          saved_recap: @engine.saved_recap,
          continue_offer: @accumulator.continue_offer,
          guardrail_warning: @engine.guardrail_warning,
          event_seq: seq,
          event_id: event_id(seq)
        }
      end
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

    # Wait up to +timeout+ seconds for connection threads still answering a
    # request (see handle_connection).
    def await_answers(timeout)
      deadline = monotonic_now + timeout
      while monotonic_now < deadline
        busy = @connection_threads.any? { |t| t != Thread.current && t.alive? && t[:bridge_answering] }
        break unless busy

        sleep(0.01)
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

        note_client_activity

        method = request[:method].to_s.upcase
        headers = request[:headers]
        # Every request but a stream gets its answer before #stop kills this
        # thread; a stream never ends on its own.
        Thread.current[:bridge_answering] = !(stream_match(request[:path]) && method == "GET")

        if request[:too_large]
          write_json(io, 413, { "Connection" => "close" }, { error: "too_large", detail: "request body over #{MAX_BODY_BYTES} bytes" })
          break
        elsif method == "OPTIONS"
          write_json(io, 204, cors, {})
        elsif (m = stream_match(request[:path])) && method == "GET"
          cursor = reconnect_cursor(headers, request[:query])
          serve_sse(io, m[1], last_event_id: cursor, snapshot: snapshot_requested?(request[:query]),
                              client_id: stream_client_id(request[:query]))
          break # SSE owns the connection until the client disconnects.
        elsif (m = cancel_match(request[:path])) && method == "POST"
          payload, status, body = handle_cancel(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = answer_match(request[:path])) && method == "POST"
          payload, status, body = handle_answer(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = dismiss_match(request[:path])) && method == "POST"
          payload, status, body = handle_dismiss_question(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = turn_match(request[:path])) && method == "POST"
          payload, status, body = handle_post_turn(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = command_match(request[:path])) && method == "POST"
          payload, status, body = handle_command(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = exit_match(request[:path])) && method == "POST"
          payload, status, body = handle_exit_request(m[1], request[:body])
          write_json(io, status, payload, body)
        elsif (m = recap_match(request[:path])) && method == "POST"
          payload, status, body = handle_recap(m[1])
          write_json(io, status, payload, body)
        elsif (m = state_match(request[:path])) && method == "GET"
          payload, status, body = handle_state(m[1])
          write_json(io, status, payload, body)
        elsif (m = stats_match(request[:path])) && method == "GET"
          payload, status, body = handle_stats(m[1])
          write_json(io, status, payload, body)
        elsif (m = snapshot_match(request[:path])) && method == "GET"
          payload, status, body = handle_snapshot(m[1])
          write_json(io, status, payload, body)
        else
          write_json(io, 404, { "Allow" => "GET, POST, OPTIONS" },
                     { error: "not_found", path: request[:path] })
        end

        Thread.current[:bridge_answering] = false
        break if close_after_request?(headers)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    ensure
      Thread.current[:bridge_answering] = false
      begin
        io.close
      rescue StandardError
        nil
      end
    end

    # Serve an SSE stream. Owns the connection until the client disconnects.
    # The connection thread IS the writer thread: serve! blocks until then.
    def serve_sse(io, session_id, last_event_id:, snapshot: false, client_id: nil)
      unless own_session?(session_id)
        write_json(io, 404, {}, { error: "unknown_session" })
        return
      end

      writer = SSEWriter.new(
        engine: @engine,
        ring: @ring,
        session_id: @session_id,
        last_event_id: last_event_id,
        epoch: @epoch,
        snapshot_provider: -> { @engine.session_state_snapshot },
        turn_snapshot_provider: -> { self.snapshot },
        # A reconnect (with a cursor) replays; only a fresh join snapshots.
        join_with_snapshot: snapshot && last_event_id.nil?,
        bridge: self,
        heartbeat_interval: @heartbeat_interval
      )
      @mutex.synchronize do
        @open_streams += 1
        @streams_by_client[client_id] += 1 if client_id
      end
      begin
        writer.serve!(io)
      ensure
        @mutex.synchronize do
          @open_streams -= 1
          if client_id
            @streams_by_client[client_id] -= 1
            @streams_by_client.delete(client_id) unless @streams_by_client[client_id].positive?
          end
        end
        note_client_activity
      end
    end

    # Never takes the event log: the lock order is events, then @mutex.
    def note_client_activity
      @mutex.synchronize { @last_client_activity_at = monotonic_now }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
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

    def stats_match(path)
      %r|\A/session/([^/]+)/stats\z|u.match(path.to_s)
    end

    def snapshot_match(path)
      %r|\A/session/([^/]+)/snapshot\z|u.match(path.to_s)
    end

    def cancel_match(path)
      %r|\A/session/([^/]+)/cancel\z|u.match(path.to_s)
    end

    def answer_match(path)
      %r|\A/session/([^/]+)/answer\z|u.match(path.to_s)
    end

    def dismiss_match(path)
      %r|\A/session/([^/]+)/question/dismiss\z|u.match(path.to_s)
    end

    def command_match(path)
      %r|\A/session/([^/]+)/command\z|u.match(path.to_s)
    end

    def exit_match(path)
      %r|\A/session/([^/]+)/exit\z|u.match(path.to_s)
    end

    def recap_match(path)
      %r|\A/session/([^/]+)/recap\z|u.match(path.to_s)
    end

    # /recap in an attached TUI: the saved recap, and a new one asked for at
    # once (it arrives as :recap_ready). Answers mid-turn too.
    # 200 {enabled:, saved:, request:, min_user_turns:}. Returns [headers, status, body].
    def handle_recap(session_id)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)

      recap = @engine.recap
      return [{}, 200, { enabled: false }] unless recap

      saved = @engine.saved_recap
      [{}, 200, { enabled: true, saved: saved, request: @engine.request_recap.to_s, min_user_turns: recap.min_user_turns }]
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
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
        reason = CANCEL_REASONS.include?(r.to_s.strip) ? r.to_s.strip.to_sym : :manual
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
      rescue Engine::QuestionNotPending => e
        # Another client answered first, or the question was cancelled.
        [{}, 409, { error: "question_not_pending", detail: e.message }]
      rescue ArgumentError => e
        [{}, 400, { error: "invalid_answer", detail: e.message }]
      rescue StandardError => e
        [{}, 500, { error: "bridge_error", detail: e.message }]
      end
    end

    # Dismiss the pending question (an empty answer, as in the REPL): the
    # tool returns without an answer and every UI gets :question_cancelled.
    # Only the question the client saw, and only while nobody has answered
    # it: Engine#cancel_question checks both under the question lock.
    # Returns [headers, status, body].
    def handle_dismiss_question(session_id, body)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      qid = fetched(parsed, "id").to_s
      return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "id required" }] if qid.strip.empty?

      dismissed = @engine.cancel_question("dismissed", id: qid)
      return [{}, 409, { error: "question_not_pending", detail: "no pending question #{qid}" }] unless dismissed

      [{}, 200, { status: "dismissed", id: qid, session_id: @session_id }]
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # Queue a session command (/model, /models, !rollback, !cmd, /continue)
    # for the worker loop, which runs it between turns and announces
    # :command_ran (busy while a turn runs). Answers at once: the queueing
    # and its :command_queued are one step of the event log, so the
    # :command_ran always comes after. Only the syntax is checked here.
    # Returns [headers, status, body].
    def handle_command(session_id, body)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)
      return [{}, 501, { error: "commands_unavailable" }] unless @on_command

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      line = fetched(parsed, "line").to_s.strip
      unless SessionCommands.command?(line)
        return [{ "Allow" => "POST" }, 400, { error: "unknown_command", detail: "not a session command: #{line[0, 80]}" }]
      end

      command = { command_id: SecureRandom.uuid, client_id: fetched(parsed, "client_id"), line: line }
      @engine.synchronize_events do
        @on_command.call(command)
        @engine.announce(type: :command_queued, **command)
      end
      [{}, 202, { status: "accepted", command_id: command[:command_id], session_id: @session_id }]
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # A client asks the worker to exit now (`/exit` in the attached TUI). The
    # worker decides with the event log held, so no POST /turn lands between
    # its check and its answer; it leaves from its loop after this reply.
    # 200 {status: "exiting", discard?: the session is empty and goes}, or 409 {status: "held", reason:} naming what
    # keeps it up. Returns [headers, status, body].
    def handle_exit_request(session_id, body)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)
      return [{}, 501, { error: "exit_unavailable" }] unless @on_exit_request

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      client_id = fetched(parsed, "client_id")
      delete = fetched(parsed, "delete") == true
      reason = @engine.synchronize_events { @on_exit_request.call(client_id, delete: delete) }
      if reason.nil?
        body = { status: "exiting", session_id: @session_id }
        body[:discard] = @exit_discards.call == true if @exit_discards
        return [{}, 200, body]
      end

      [{}, 409, { status: "held", reason: reason.to_s, session_id: @session_id }]
    rescue StandardError => e
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # Create a turn via file IPC (fire-and-forget). Returns [headers, status, body].
    def handle_post_turn(session_id, body)
      parsed = parse_json(body)
      unless parsed.is_a?(Hash)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }]
      end

      sid = fetched(parsed, "session_id")
      prompt = fetched(parsed, "prompt")
      client_id = fetched(parsed, "client_id")
      # --no-interrupt: the turn runs with the raised iteration limit.
      no_interrupt = fetched(parsed, "no_interrupt") == true
      if sid.to_s.strip.empty? || prompt.to_s.strip.empty?
        return [{ "Allow" => "POST" }, 400,
                { error: "missing_fields", detail: "session_id and prompt are required" }]
      end
      images = turn_images(sid, fetched(parsed, "images"))
      return [{}, 400, { error: "bad_images", detail: images }] if images.is_a?(String)

      enqueued_id = SecureRandom.uuid
      enqueued =
        if own_session?(sid)
          # Write and announce with the event log held: the worker can't
          # emit this turn's :turn_started (or merge it mid-turn) before
          # :turn_enqueued, and a failed write announces nothing.
          @engine.synchronize_events do
            enqueue_turn(session_id: sid, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                         no_interrupt: no_interrupt, images: images).tap do |ok|
              next unless ok

              enqueued_event = { type: :turn_enqueued, enqueued_id: enqueued_id, client_id: client_id, prompt: prompt.to_s }
              enqueued_event[:images] = images unless images.empty?
              @engine.announce(enqueued_event)
              @on_input&.call
            end
          end
        else
          enqueue_turn(session_id: sid, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                       no_interrupt: no_interrupt, images: images)
        end
      return [{}, 500, { error: "enqueue_failed", detail: "could not write turn input" }] unless enqueued

      [{}, 202, { status: "accepted", enqueued_id: enqueued_id, session_id: sid }]
    rescue StandardError => e
      # SessionManager loads lazily (enqueue_turn).
      if defined?(SessionManager::ImagesUnsupported) && e.is_a?(SessionManager::ImagesUnsupported)
        return [{}, 409, { error: "images_unsupported", detail: e.message }]
      end

      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # Read-only snapshot surface. AC #4: too-old reconnects re-derive state
    # from here.
    def handle_state(session_id)
      unless own_session?(session_id)
        return [{}, 404, { error: "unknown_session" }]
      end

      state = @engine.session_state_snapshot
      [{}, 200, { session_id: @session_id, session_state_snapshot: state.merge(event_id: event_id(state[:event_seq])) }]
    end

    # /stats for an attached client: the metrics, with the window and prompt
    # profile asked from the server when no turn has reported them yet (so,
    # unlike /state, it may wait on one short /props GET).
    def handle_stats(session_id)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)

      [{}, 200, { session_id: @session_id, metrics: @engine.stats_snapshot }]
    end

    # The snapshot frame's content as one request, for a client that renders
    # the messages elsewhere (the web server strips and formats them): it then
    # streams from the snapshot's event_seq, and the ring replays what came
    # after (or the stream resets). Returns [headers, status, body].
    def handle_snapshot(session_id)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)

      body = @engine.synchronize_events do
        snap = snapshot
        state = @engine.session_state_snapshot.merge(event_seq: snap[:event_seq], event_id: snap[:event_id])
        { snapshot: snap, session_state_snapshot: state }
      end
      [{}, 200, body]
    end

    # The stream cursor for +seq+ in this worker.
    def event_id(seq)
      EventId.format(seq.to_i, @epoch)
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
    def enqueue_turn(session_id:, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, images: [])
      require_relative "session_manager"
      Samagotchi::SessionManager.write_turn_input(
        session_id, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id, no_interrupt: no_interrupt,
                    state_dir: @state_dir, images: images
      )
    rescue LoadError
      # SessionManager not available (e.g. bridge used standalone in a spec).
      false
    end

    # A turn's images as [{file:, name:}], or a String saying what's wrong.
    # Only refs to files already in that session's images/ pass (a web
    # upload): never a path, so no client can make the worker read a file.
    def turn_images(session_id, raw)
      return [] if raw.nil?
      return "images must be a list" unless raw.is_a?(Array)
      return "at most #{MAX_TURN_IMAGES} images" if raw.size > MAX_TURN_IMAGES

      session_dir = Session.session_dir(session_id, state_dir: @state_dir || Session.default_state_dir)
      raw.map do |image|
        return "each image must be {file:, name:}" unless image.is_a?(Hash)

        ref = ImageStore.symbolize(image)
        return "images are refs to uploaded files, not paths" if ref.key?(:path)
        return "unknown image #{ref[:file].to_s[0, 80]}" unless ImageStore.valid_ref?(session_dir, ref)

        { file: ref[:file].to_s, name: File.basename(ref[:name].to_s)[0, 120] }
      end
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

      # Nothing a client sends is this big (images travel as refs): the body
      # is skipped, not kept, so the client reads a 413 rather than a reset.
      too_large = content_length > MAX_BODY_BYTES
      skip_body(io, content_length) if too_large
      body = content_length > 0 && !too_large ? io.read(content_length) : nil
      path, query = split_target(target)
      { method: method, path: path, query: query, headers: headers, body: body, too_large: too_large }
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    end

    def skip_body(io, length)
      left = [length, 32 * MAX_BODY_BYTES].min
      while left.positive?
        chunk = io.read([left, 65_536].min)
        break if chunk.nil? || chunk.empty?

        left -= chunk.bytesize
      end
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

    # `?snapshot=1`: join with a snapshot frame instead of a replay.
    def snapshot_requested?(query)
      return false unless query

      URI.decode_www_form(query).to_h["snapshot"].to_s == "1"
    rescue StandardError
      false
    end

    # `?client_id=`: whose stream it is (see #open_streams_except).
    def stream_client_id(query)
      return nil unless query

      id = URI.decode_www_form(query).to_h["client_id"].to_s
      id.empty? ? nil : id
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
      record["input_format"] = @input_format if @input_format
      path = File.join(session_dir, SIDECAR_FILE)
      FileUtils.mkdir_p(session_dir)
      temp = "#{path}.tmp"
      File.write(temp, JSON.pretty_generate(record) + "\n")
      File.rename(temp, path)
    rescue StandardError => e
      warn "Bridge: failed to write #{SIDECAR_FILE}: #{e.class}: #{e.message}"
    end

    # Only while it still names this bridge: a racing worker for the same
    # session may have written its own since.
    def remove_sidecar
      path = File.join(session_dir, SIDECAR_FILE)
      return unless @server && File.file?(path)

      File.unlink(path) if JSON.parse(File.read(path))["port"].to_i == @port
    rescue StandardError
      nil
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
      409 => "Conflict",
      500 => "Internal Server Error",
      501 => "Not Implemented"
    }.freeze
  end
end
