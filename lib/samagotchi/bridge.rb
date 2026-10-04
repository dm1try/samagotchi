# frozen_string_literal: true

require "socket"
require "json"
require "uri"
require "fileutils"
require "securerandom"
require "time"
require_relative "atomic_file"
require_relative "session_inbox"

require_relative "bridge/bounded_queue"
require_relative "bridge/card_store"
require_relative "bridge/event_id"
require_relative "bridge/pending_card"
require_relative "bridge/ring_buffer"
require_relative "bridge/sse_writer"
require_relative "bridge/turn_accumulator"
require_relative "session"
require_relative "engine"
require_relative "guardrails/parent_approvals"
require_relative "session_commands"
require_relative "image_store"
require_relative "log"
require_relative "version"
require_relative "worker_sidecar"
require_relative "relay_verifier"
require_relative "relay_watcher"

module Samagotchi
  # Bridge is an optional HTTP transport that lets an external web / desktop
  # client reach the owner process (the forked session-worker) and receive the
  # Engine's live event stream via Server-Sent Events, and optionally create a
  # turn via HTTP POST.
  #
  # Design invariants (see multi_ui_architecture):
  # * Reuses `Engine#subscribe` for SSE fan-out — never a second Engine, never
  #   `run_turn` across the thread/process boundary. POST reuses the
  #   `SessionInbox` file-IPC input path.
  # * One capture observer fills a shared ring buffer; each connection gets a
  #   per-connection live queue (see SSEWriter).
  # * Binds 127.0.0.1 only. There is NO auth: binding 0.0.0.0 exposes remote
  #   turn-execution (RCE). Documented, not fixed.
  # * Optional at runtime: this module is never loaded unless explicitly
  #   engaged as a transport.
  class Bridge
    DEFAULT_BIND = "127.0.0.1"
    DEFAULT_RING_CAPACITY = 256
    DEFAULT_HEARTBEAT_INTERVAL = 15.0
    # Cancel reasons a client may name (the web sends user, an attached TUI
    # ctrl_c); anything else is :manual, so client input never mints symbols.
    CANCEL_REASONS = %w[manual user ctrl_c].freeze
    # How long #stop waits for requests it is answering (not open streams).
    REQUEST_GRACE_SECONDS = 1.0
    # The largest request body read (images travel as refs, never bytes).
    MAX_BODY_BYTES = 1_000_000
    # A request's deadline (see #handle_post_turn) that isn't epoch seconds.
    BAD_DEADLINE = [{ "Allow" => "POST" }, 400, { error: "bad_deadline", detail: "deadline must be epoch seconds" }].freeze

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
    #   SessionInbox::INPUT_FORMAT); nil advertises none
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
      # Saved in the session's folder: a later worker, and the web without
      # one, show the cards where they were.
      @cards = CardStore.new(path: File.join(session_dir, CardStore::FILE))
      @pending_card = PendingCard.new(session_dir)
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
    # count. A closed stream stops counting once its writer reads the
    # hang-up (SSEWriter#watch_hangup).
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
      # A plugin's ctx.messages mid-turn holds the turn so far (plan O1).
      @engine.running_turn_messages = -> { @accumulator.current_messages }
      @cards_handle = @engine.subscribe(observer: @cards)
      # One a worker that died left is not open.
      @pending_card.clear
      @pending_card_handle = @engine.subscribe(observer: @pending_card)
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
      @engine.running_turn_messages = nil
      @cards_handle&.unsubscribe
      @pending_card_handle&.unsubscribe
      @pending_card&.clear
      # A turn post killed between its enqueue and its reply looks failed to
      # the web, which then queues the prompt again from the input file.
      await_answers(REQUEST_GRACE_SECONDS)
      @connection_threads.each { |t| t.kill rescue nil }
      @connection_threads.clear
      @mutex.synchronize { @relay_watchers&.each { |t| t.kill rescue nil } }
      @accept_thread&.join(2)
      remove_sidecar
      nil
    end

    # What a joining client needs to render the session now, consistent with
    # the event log: the Engine's messages (not the lagging copy on disk),
    # the turn in progress, turns queued behind it, the idle recap since the
    # last turn, the recap saved with the session (also from before the last
    # turns: {text:, covered:, turns_since:, created_at:}), a pending continue offer, the guardrail and plugin load warnings,
    # the plugins' init tasks still running (Engine#init_tasks), the
    # last cards and between-turns notices (CardStore#list), the session's commands (Commands::Registry#listing:
    # what an attached TUI routes and completes, the web's autocomplete), and the event_seq it all covers.
    # Taken with the log held, so no event is half-applied.
    # The pending question at the top level too: one asked between turns
    # (the step-limit question) belongs to no turn, so the accumulator
    # doesn't keep it.
    # chi_version: the chi this worker runs (an attaching TUI compares it
    # with its own).
    # @return [Hash] {messages:, current_turn:, queued:, recap:, saved_recap:, continue_offer:, pending_question:,
    #   guardrail_warning:, plugin_warning:, init_tasks:, cards:, commands:, chi_version:, event_seq:, event_id:}
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
          pending_question: @engine.pending_question,
          guardrail_warning: @engine.guardrail_warning,
          plugin_warning: @engine.plugin_warning,
          init_tasks: @engine.init_tasks,
          cards: @cards.list,
          commands: command_registry.listing,
          chi_version: Samagotchi::VERSION,
          event_seq: seq,
          event_id: event_id(seq)
        }
      end
    end

    # The snapshot and the session state (status, pending question, ...) as
    # one step of the event log, both as of the same event_seq: what a
    # snapshot or reset frame (SSEWriter) and GET snapshot carry.
    # @return [Hash] {snapshot:, session_state_snapshot:}
    def snapshot_frame
      @engine.synchronize_events do
        snap = snapshot
        state = @engine.session_state_snapshot.merge(event_seq: snap[:event_seq], event_id: snap[:event_id])
        { snapshot: snap, session_state_snapshot: state }
      end
    end

    # What the page re-reads at a turn's end and when a card arrives: the
    # session state, the last answer (Engine#last_answer_message: one
    # message, not the conversation) and the cards, as one step of the event
    # log (one event_seq). Light whatever the session's length: GET tail.
    # @return [Hash] {session_id:, session_state_snapshot:, answer:, cards:, event_seq:, event_id:}
    # +turn_id+: that turn's answer, not the newest (Engine#last_answer_message).
    def tail_frame(turn_id: nil)
      @engine.synchronize_events do
        seq = @engine.event_count
        state = @engine.session_state_snapshot.merge(event_seq: seq, event_id: event_id(seq))
        { session_id: @session_id, session_state_snapshot: state, answer: @engine.last_answer_message(turn_id: turn_id),
          cards: @cards.list, event_seq: seq, event_id: event_id(seq) }
      end
    end

    # The worker's own way in for a session command that came as a message
    # (its first prompt, an input file): queued and announced as a POST
    # /command's is (#handle_command).
    # @return [String] its command_id
    def queue_command(line, client_id: nil, card: false)
      command = { command_id: SecureRandom.uuid, client_id: client_id, line: line.to_s.strip }
      # A card's action (the step-limit question's answer): the UIs leave
      # its line out.
      command[:card] = true if card
      @engine.synchronize_events { queue_command_locked(command) }
      command[:command_id]
    end

    private

    # The Engine's commands: the built-ins and its plugins'.
    def command_registry
      @engine.command_registry
    end

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
    rescue StandardError => e
      # No accept loop, no bridge: every client of this worker loses it.
      # (#stop closing the server ends the loop the same way: not a failure.)
      Log.exception(:bridge, "accept_loop_failed", e) unless stopped?
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
        started = monotonic_now

        method = request[:method].to_s.upcase
        headers = request[:headers]
        route = route_for(method, request[:path])
        # Every request but a stream gets its answer before #stop kills this
        # thread; a stream never ends on its own.
        Thread.current[:bridge_answering] = route&.first != :stream

        if request[:too_large]
          write_json(io, 413, { "Connection" => "close" }, { error: "too_large", detail: "request body over #{MAX_BODY_BYTES} bytes" })
          break
        elsif browser_request?(headers)
          write_json(io, 403, nil, { error: "cross_origin", detail: "the bridge answers chi's own clients only" })
        elsif route.nil?
          write_json(io, 404, { "Allow" => "GET, POST" },
                     { error: "not_found", path: request[:path] })
        elsif route.first == :stream
          cursor = reconnect_cursor(headers, request[:query])
          Log.debug(:bridge, "stream", method: method, path: request[:path], client_id: stream_client_id(request[:query]))
          serve_sse(io, route.last, last_event_id: cursor, snapshot: snapshot_requested?(request[:query]),
                                    client_id: stream_client_id(request[:query]))
          break # SSE owns the connection until the client disconnects.
        else
          payload, status, body = dispatch(route.first, route.last, request[:body], request[:query])
          write_json(io, status, payload, body)
        end

        Thread.current[:bridge_answering] = false
        log_request(method, request[:path], started)
        break if close_after_request?(headers)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      nil
    rescue StandardError => e
      # The thread doesn't report (report_on_exception = false): log it.
      Log.exception(:bridge, "connection_failed", e)
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
        frame_provider: -> { snapshot_frame },
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

    LOOPBACK_NAMES = %w[127.0.0.1 [::1] localhost].freeze

    # Only chi's Ruby clients talk to the Bridge, and they send no Origin and
    # no Sec-Fetch-Site. A browser page always sends one of them (another
    # website's text/plain POST needs no preflight), and a DNS-rebound page
    # also has a foreign Host. Headers are the raw ones, lowercased.
    def browser_request?(headers)
      return true if headers.key?("origin")
      return true if headers.key?("sec-fetch-site") && headers["sec-fetch-site"].downcase != "none"

      host = headers["host"].to_s
      !host.empty? && !LOOPBACK_NAMES.include?(host.downcase.sub(/:\d*\z/, ""))
    end

    # What a client may ask of this worker beyond the routes, named in its
    # sidecar (WorkerSidecar#features): a client checks a name here rather
    # than a version.
    # restart: POST /exit takes "restart": true (WorkerIdleExit#hold_for_restart).
    FEATURES = ["restart"].freeze

    # The routes, by method and what follows /session/:id/: a handler takes
    # the session id and the request body and returns [headers, status, body].
    # GET stream is served apart (#serve_sse owns the connection).
    ROUTES = {
      %w[GET stream] => :stream,
      %w[POST cancel] => :handle_cancel,
      %w[POST answer] => :handle_answer,
      %w[POST question/dismiss] => :handle_dismiss_question,
      %w[POST turn] => :handle_post_turn,
      %w[POST command] => :handle_command,
      %w[POST exit] => :handle_exit_request,
      %w[POST recap] => :handle_recap,
      %w[POST relay] => :handle_relay,
      %w[POST relay/status] => :handle_relay_status,
      %w[GET state] => :handle_state,
      %w[GET stats] => :handle_stats,
      %w[GET snapshot] => :handle_snapshot,
      %w[GET tail] => :handle_tail
    }.freeze
    ROUTE_PATH = %r|\A/session/([^/]+)/(.+)\z|u

    # @return [Array(Symbol, String), nil] the handler and the session id, or
    #   nil when no route takes this method and path
    def route_for(method, path)
      m = ROUTE_PATH.match(path.to_s) or return nil
      handler = ROUTES[[method, m[2]]] or return nil
      [handler, m[1]]
    end

    # Every route but the stream: only this bridge's own session (see
    # #own_session?), and a handler that raises answers 500 bridge_error,
    # logged (the connection thread doesn't report).
    # @return [Array(Hash, Integer, Hash)] headers, status, body
    # Only GET tail takes the request's +query+.
    def dispatch(handler, session_id, body, query = nil)
      return [{}, 404, { error: "unknown_session" }] unless own_session?(session_id)
      return handle_tail(session_id, body, query) if handler == :handle_tail

      send(handler, session_id, body)
    rescue StandardError => e
      Log.exception(:bridge, "handler_failed", e)
      [{}, 500, { error: "bridge_error", detail: e.message }]
    end

    # /recap in an attached TUI: the saved recap, and a new one asked for at
    # once (it arrives as :recap_ready). Answers mid-turn too.
    # 200 {enabled:, saved:, request:, min_user_turns:}. Returns [headers, status, body].
    def handle_recap(session_id, _body = nil)
      recap = @engine.recap
      return [{}, 200, { enabled: false }] unless recap

      saved = @engine.saved_recap
      [{}, 200, { enabled: true, saved: saved, request: @engine.request_recap.to_s, min_user_turns: recap.min_user_turns }]
    end

    # Cancel the active turn on this session's engine, if any.
    # Returns [headers, status, body].
    def handle_cancel(session_id, body)
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
    end

    # Answer the pending question. A past +deadline+ (see #handle_post_turn):
    # 408 deadline_passed, and the question stays open. An answer takes no
    # event hold, so it is checked right before it is recorded.
    def handle_answer(session_id, body)
      parsed = parse_json(body)
      unless parsed.is_a?(Hash)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }]
      end

      qid = fetched(parsed, "id")
      selected = fetched(parsed, "selected")
      freeform = fetched(parsed, "freeform")
      # chi answer's marker: a parent agent, held to this worker's
      # guardrails.parent_approvals (QuestionDesk::Refused). Not a boundary:
      # any local process may post here, with or without it.
      client_id = fetched(parsed, "client_id")
      if qid.to_s.strip.empty?
        return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "id required" }]
      end

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)
      return deadline_passed("answer") if expired?("answer_expired", deadline, sid: session_id, id: qid)

      begin
        result = @engine.answer_question(id: qid, selected: selected, freeform: freeform, client_id: client_id)
        [{}, 200, { status: "answered", session_id: session_id, answer: result }]
      rescue Engine::QuestionNotPending => e
        # Another client answered first, or the question was cancelled.
        [{}, 409, { error: "question_not_pending", detail: e.message }]
      rescue QuestionDesk::Refused => e
        Log.info(:bridge, "parent_approval_refused", sid: session_id, id: qid, reason: e.reason)
        [{}, 403, { error: e.reason == :stop_only ? "parent_continue_refused" : "parent_approval_refused",
                    detail: Guardrails::ParentApprovals.message(e.reason) }]
      rescue ArgumentError => e
        [{}, 400, { error: "invalid_answer", detail: e.message }]
      end
    end

    # What a parent's relay may say about this session's approval
    # (BridgeClient#relay): opened and closed only change how the question
    # shows (QuestionDesk#annotate); answered makes this worker ask the
    # parent for the answer (RelayVerifier). No auth: a poke at opened or
    # closed can at most show a wrong banner.
    RELAY_ACTIONS = %w[opened closed answered].freeze
    # Why a relay closed, as a parent says it; anything else is "closed".
    RELAY_CLOSE_REASONS = %w[stopped closed child_gone answered_on_child].freeze

    # POST /session/:id/relay {action, relay_id, question_id}. 200, 409 (no
    # longer pending, or another relay's), 403 refused (a parent agent's
    # allow), 422 relay_unverified, 400 a bad request.
    def handle_relay(session_id, body)
      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      action, relay_id, qid = %w[action relay_id question_id].map { |key| fetched(parsed, key).to_s }
      unless RELAY_ACTIONS.include?(action) && !relay_id.empty? && !qid.empty?
        return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "action (opened, closed, answered), relay_id and question_id required" }]
      end

      case action
      when "opened" then relay_opened(qid, relay_id)
      when "closed"
        reason = fetched(parsed, "reason").to_s
        relay_closed(qid, relay_id, RELAY_CLOSE_REASONS.include?(reason) ? reason : "closed")
      else
        RelayVerifier.new(engine: @engine, state_dir: @state_dir, session_id: session_id)
                     .answer(relay_id: relay_id, question_id: qid)
      end
    end

    # Dismiss the pending question (an empty answer, as in the REPL): the
    # tool returns without an answer and every UI gets :question_cancelled.
    # Only the question the client saw, and only while nobody has answered
    # it: Engine#cancel_question checks both under the question lock. A past
    # +deadline+ (dismissing an approval denies it): 408, as for an answer.
    # Returns [headers, status, body].
    def handle_dismiss_question(session_id, body)
      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      qid = fetched(parsed, "id").to_s
      return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "id required" }] if qid.strip.empty?

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)
      return deadline_passed("dismissal") if expired?("dismiss_expired", deadline, sid: session_id, id: qid)

      begin
        dismissed = @engine.cancel_question("dismissed", id: qid)
      rescue QuestionDesk::NotDismissable => e
        # A step-limit question: its answer is Continue or Stop.
        return [{}, 409, { error: "not_dismissable", detail: e.message }]
      end
      return [{}, 409, { error: "question_not_pending", detail: "no pending question #{qid}" }] unless dismissed

      [{}, 200, { status: "dismissed", id: qid, session_id: @session_id }]
    end

    # Queue a session command (/model, /models, !rollback, !cmd, /continue)
    # for the worker loop, which runs it between turns and announces
    # :command_ran (busy while a turn runs). Answers at once: the queueing
    # and its :command_queued are one step of the event log, so the
    # :command_ran always comes after. Only the syntax is checked here. A
    # past +deadline+ (see #handle_post_turn), checked with the event log
    # held: 408 deadline_passed, not run. Every command is checked, the
    # read-only ones (/models) too: its client said it didn't run.
    # Returns [headers, status, body].
    def handle_command(session_id, body)
      return [{}, 501, { error: "commands_unavailable" }] unless @on_command

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      line = fetched(parsed, "line").to_s.strip
      # The Engine's own commands: the built-ins and its plugins' (a card's
      # action is a plugin command line).
      unless command_registry.command?(line)
        known = command_registry.entries.reject(&:local).map { |entry| SessionCommands.display_name(entry) }.sort
        detail = "not a session command: #{line[0, 80]} (known: #{known.join(", ")}; /help lists them)"
        return [{ "Allow" => "POST" }, 400, { error: "unknown_command", detail: detail }]
      end

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      queue_command_request(session_id, line, client_id: fetched(parsed, "client_id"), deadline: deadline,
                                              card: fetched(parsed, "card") == true)
    end

    # Queues +line+ (a session command) for the worker and announces its
    # :command_queued, unless +deadline+ has passed. Returns [headers,
    # status, body]: 202 with its command_id, or 408.
    def queue_command_request(session_id, line, client_id:, deadline: nil, card: false)
      command = { command_id: SecureRandom.uuid, client_id: client_id, line: line }
      # A card's action: the UIs leave its line out (the card is the echo).
      command[:card] = true if card
      queued = @engine.synchronize_events do
        next false if expired?("command_expired", deadline, sid: session_id, client_id: command[:client_id])

        queue_command_locked(command)
        true
      end
      return deadline_passed("command") unless queued

      [{}, 202, { status: "accepted", command_id: command[:command_id], session_id: @session_id }]
    end

    # With the event log held.
    def queue_command_locked(command)
      @on_command.call(command)
      # An anytime command runs now, beside a turn (D8): the UIs show its
      # line here, so the cards it shows come after it.
      anytime = command_registry.lookup(command[:line])&.anytime ? { anytime: true } : {}
      @engine.announce(type: :command_queued, **command, **anytime)
    end

    # A client asks the worker to exit now (`/exit` in the attached TUI), or
    # with "restart": true to hand the session to a new worker on the newest
    # chi installed (the "restart" feature). The worker decides with the
    # event log held, so no POST /turn lands between its check and its
    # answer; it leaves from its loop after this reply.
    # 200 {status: "exiting", discard?: the session is empty and goes} ({status: "restarting"} for a restart), or 409
    # {status: "held", reason:} naming what keeps it up. A past +deadline+
    # (see #handle_post_turn), checked with the event log held: 408
    # deadline_passed, the worker not asked (its client said it didn't stop).
    # Returns [headers, status, body].
    def handle_exit_request(session_id, body)
      return [{}, 501, { error: "exit_unavailable" }] unless @on_exit_request

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      client_id = fetched(parsed, "client_id")
      delete = fetched(parsed, "delete") == true
      restart = fetched(parsed, "restart") == true
      options = restart ? { delete: delete, restart: true } : { delete: delete }
      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      reason = @engine.synchronize_events do
        next :expired if expired?("exit_expired", deadline, sid: session_id, client_id: client_id)

        @on_exit_request.call(client_id, **options)
      end
      return deadline_passed("exit request") if reason == :expired

      if reason.nil?
        return [{}, 200, { status: "restarting", session_id: @session_id }] if restart

        body = { status: "exiting", session_id: @session_id }
        body[:discard] = @exit_discards.call == true if @exit_discards
        return [{}, 200, body]
      end

      [{}, 409, { status: "held", reason: reason.to_s, session_id: @session_id }]
    end

    # Queue a turn for this session through its file IPC (the worker polls
    # its input dir). Returns [headers, status, body]. Only this bridge's own
    # session: another id, in the path or the body, is refused as on every
    # other route.
    #
    # A +deadline+ (wall-clock epoch seconds; the client shares this machine's
    # clock) is when the client stops waiting (BridgeClient#post_turn): a turn
    # past it waited in the socket while this worker was frozen (a sleeping
    # Mac, SIGSTOP) and its client has already said it was not sent, so it is
    # dropped with 408 deadline_passed. It is checked with the event log held,
    # right before the write, so nothing that holds the log (an exit check)
    # can delay an accepted turn past it. No deadline (an older client): taken.
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
      return [{}, 404, { error: "unknown_session" }] unless own_session?(sid)

      images = ImageStore.check_refs(session_dir, fetched(parsed, "images"))
      return [{}, 400, { error: "bad_images", detail: images }] if images.is_a?(String)

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      # A session command sent as a message (chi send -m "/model x", chi -p,
      # a UI whose command list lags) runs as the command, as typed in a
      # TUI; an unknown /word stays a prompt. Not with images: those are
      # for the model.
      if images.empty? && @on_command && command_registry.command?(prompt.to_s)
        return queue_command_request(sid, prompt.to_s.strip, client_id: client_id, deadline: deadline)
      end

      enqueued_id = SecureRandom.uuid
      # Write and announce with the event log held: the worker can't emit
      # this turn's :turn_started (or merge it mid-turn) before
      # :turn_enqueued, and a failed write announces nothing.
      enqueued = @engine.synchronize_events do
        next :expired if expired?("turn_expired", deadline, sid: sid, client_id: client_id)

        enqueue_turn(prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                     no_interrupt: no_interrupt, images: images).tap do |ok|
          next unless ok

          enqueued_event = { type: :turn_enqueued, enqueued_id: enqueued_id, client_id: client_id, prompt: prompt.to_s }
          enqueued_event[:images] = images unless images.empty?
          @engine.announce(enqueued_event)
          @on_input&.call
        end
      end
      return deadline_passed("turn") if enqueued == :expired
      return [{}, 500, { error: "enqueue_failed", detail: "could not write turn input" }] unless enqueued

      [{}, 202, { status: "accepted", enqueued_id: enqueued_id, session_id: @session_id }]
    end

    # Read-only snapshot surface. AC #4: too-old reconnects re-derive state
    # from here.
    def handle_state(session_id, _body = nil)
      state = @engine.session_state_snapshot
      [{}, 200, { session_id: @session_id, session_state_snapshot: state.merge(event_id: event_id(state[:event_seq])) }]
    end

    # /stats for an attached client: the metrics, with the window and prompt
    # profile asked from the server when no turn has reported them yet (so,
    # unlike /state, it may wait on one short /props GET).
    def handle_stats(session_id, _body = nil)
      [{}, 200, { session_id: @session_id, metrics: @engine.stats_snapshot }]
    end

    # The snapshot frame's content as one request, for a client that renders
    # the messages elsewhere (the web server strips and formats them): it then
    # streams from the snapshot's event_seq, and the ring replays what came
    # after (or the stream resets). Returns [headers, status, body].
    def handle_snapshot(session_id, _body = nil)
      [{}, 200, snapshot_frame]
    end

    # The page's light re-read (#tail_frame): no message list. `?turn_id=`:
    # that turn's answer (a queued turn's page re-reads late). The one
    # handler that gets the query (#dispatch); an older worker's route
    # ignores it and sends the newest answer.
    def handle_tail(session_id, _body = nil, query = nil)
      turn_id = query && URI.decode_www_form(query).to_h["turn_id"].to_s
      [{}, 200, tail_frame(turn_id: turn_id.to_s.empty? ? nil : turn_id)]
    rescue ArgumentError
      [{}, 200, tail_frame]
    end

    # The stream cursor for +seq+ in this worker.
    def event_id(seq)
      EventId.format(seq.to_i, @epoch)
    end

    # A per-session bridge only ever owns one Engine (for @session_id). The
    # stream, state and turn surfaces must serve that session and nothing
    # else — serving a different id's data (or writing into another
    # session's input dir) would be a cross-session leak.
    def own_session?(session_id)
      session_id.to_s == @session_id.to_s
    end

    # A request's +deadline+ (see #handle_post_turn) is epoch seconds or absent.
    def deadline_valid?(deadline) = deadline.nil? || deadline.is_a?(Numeric)

    # Whether a request's +deadline+ has passed; logs +event+ with +fields+
    # and how late it was when it has.
    def expired?(event, deadline, **fields)
      return false if deadline.nil?

      late = Time.now.to_f - deadline
      return false unless late.positive?

      Log.warn(:bridge, event, **fields, late: late.round(1))
      true
    end

    # The 408 for a request read after its deadline: +what+ (turn, command,
    # answer, dismissal, exit request) was dropped.
    def deadline_passed(what)
      [{}, 408, { error: "deadline_passed", detail: "the #{what} arrived after its client stopped waiting; not run" }]
    end

    # Write a turn into this session's input dir, reusing the file IPC the
    # worker polls. Never calls run_turn across the boundary.
    def enqueue_turn(prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, images: [])
      SessionInbox.write_input(session_dir, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                                            no_interrupt: no_interrupt, images: images)
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

    # One debug line per answered request (never its body): what #write_json
    # last sent on this connection's thread.
    def log_request(method, path, started)
      return unless Log.level?(:debug)

      Log.debug(:bridge, "request", method: method, path: path, status: Thread.current[:bridge_status],
                                    ms: ((monotonic_now - started) * 1000).round)
    end

    def write_json(io, status, extra_headers, body)
      Thread.current[:bridge_status] = status
      extra_headers ||= {}
      body ||= {}
      data = JSON.generate(body)
      reason = HTTP_REASONS.fetch(status, "OK")
      headers = {
        "Content-Type" => "application/json",
        "Content-Length" => data.bytesize.to_s,
        "Connection" => "close",
        "Cache-Control" => "no-store"
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

    # POST /session/:id/relay/status {relay_id}: what this (the parent's)
    # worker's relay holds, for the child that verifies an answer
    # (RelayVerifier). Read-only and no secret; 404 for an unknown id.
    def handle_relay_status(_session_id, body)
      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      relay = @engine.relay_desk.status(fetched(parsed, "relay_id").to_s)
      return [{}, 404, { error: "unknown_relay" }] unless relay

      [{}, 200, relay]
    end

    # A parent's relay card for +qid+ opened: the question says so (the
    # child's card and lists show where else it can be answered).
    def relay_opened(qid, relay_id)
      parent_id = begin
        Session.load(@session_id, state_dir: @state_dir).parent_id
      rescue ArgumentError
        nil
      end
      return [{}, 422, { error: "relay_unverified", detail: "this session has no parent" }] unless parent_id

      marker = { parent_id: parent_id, parent_short: parent_id[0, 8], relay_id: relay_id }
      return [{}, 409, { error: "question_not_pending", detail: "no pending question #{qid}" }] unless @engine.annotate_question(qid, relayed_to: marker)

      Log.info(:bridge, "relay_opened", sid: @session_id, id: qid, parent: parent_id[0, 8])
      watch = RelayWatcher.start(engine: @engine, question_id: qid, relay_id: relay_id,
                                 parent_dir: Session.session_dir(parent_id, state_dir: @state_dir))
      @mutex.synchronize { @relay_watchers = (@relay_watchers || []).select(&:alive?) << watch }
      [{}, 200, { status: "opened", question_id: qid }]
    end

    # The parent's relay card closed unanswered: the mark goes, if it is
    # still that relay's.
    def relay_closed(qid, relay_id, reason)
      pending = @engine.pending_question
      relay = pending && pending[:relayed_to]
      unless pending && pending[:id].to_s == qid && relay && (relay[:relay_id] || relay["relay_id"]).to_s == relay_id
        return [{}, 409, { error: "question_not_pending", detail: "no question #{qid} relayed by #{relay_id}" }]
      end
      return [{}, 409, { error: "question_not_pending", detail: "no pending question #{qid}" }] unless @engine.annotate_question(qid, relayed_to: nil, reason: reason)

      Log.info(:bridge, "relay_closed", sid: @session_id, id: qid, reason: reason)
      [{}, 200, { status: "closed", question_id: qid }]
    end

    def write_sidecar
      # version: the chi this worker runs (chi update and the web's badge
      # report older ones); features: what a client may ask of it.
      WorkerSidecar.new(port: @port, bind: @bind, session_id: @session_id, started_at: Time.now.iso8601(3),
                        version: Samagotchi::VERSION, input_format: @input_format, features: FEATURES).write(session_dir)
    rescue StandardError => e
      Log.warn(:bridge, "sidecar_write_failed", echo: "Bridge: failed to write #{WorkerSidecar::FILE}: #{e.class}: #{e.message}", error: e.class.name)
    end

    # Only while it still names this bridge: a racing worker for the same
    # session may have written its own since.
    def remove_sidecar
      return unless @server

      File.unlink(WorkerSidecar.path(session_dir)) if WorkerSidecar.read(session_dir)&.port == @port
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
      403 => "Forbidden",
      404 => "Not Found",
      409 => "Conflict",
      500 => "Internal Server Error",
      501 => "Not Implemented"
    }.freeze
  end
end
