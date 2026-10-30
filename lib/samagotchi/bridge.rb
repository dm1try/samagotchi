# frozen_string_literal: true

require "socket"
require "json"
require "uri"
require "fileutils"
require "securerandom"
require "openssl"
require "time"
require_relative "atomic_file"
require_relative "bridge_secret"
require_relative "delivery"
require_relative "session_inbox"
require_relative "turn_anchors"

require_relative "bridge/bounded_queue"
require_relative "bridge/card_store"
require_relative "bridge/event_id"
require_relative "bridge/pending_card"
require_relative "bridge/ring_buffer"
require_relative "bridge/sse_writer"
require_relative "bridge/turn_accumulator"
require_relative "session"
require_relative "engine"
require_relative "system_one/log"
require_relative "session_commands"
require_relative "queued_command"
require_relative "steer"
require_relative "turn_origin"
require_relative "participants"
require_relative "image_store"
require_relative "log"
require_relative "proxy_trace"
require_relative "version"
require_relative "worker_sidecar"
require_relative "worker_link"
require_relative "relay_verifier"
require_relative "relay_watcher"
require_relative "reply_wait"
require_relative "tools/task_runtime"

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
  # * Binds 127.0.0.1 only, and answers only a request that names its secret
  #   (#secret_ok?): a random one per Bridge, in the worker's 0600 bridge.json,
  #   which only this machine's user can read. Binding 0.0.0.0 would still put
  #   remote turn-execution (RCE) one leaked secret away: don't.
  # * Optional at runtime: this module is never loaded unless explicitly
  #   engaged as a transport.
  class Bridge
    DEFAULT_BIND = "127.0.0.1"
    DEFAULT_RING_CAPACITY = 256
    DEFAULT_HEARTBEAT_INTERVAL = 15.0
    # Cancel reasons a client may name (the web sends user, an attached TUI
    # ctrl_c, a session stop session_stopped: SessionManager.stop_session);
    # anything else is :manual, so client input never mints symbols.
    CANCEL_REASONS = %w[manual user ctrl_c session_stopped].freeze
    # How long #stop waits for requests it is answering (not open streams).
    REQUEST_GRACE_SECONDS = 1.0
    # How long #stop waits for each killed RelayWatcher thread to end.
    RELAY_WATCHER_JOIN_SECONDS = 1.0
    # The largest request body read (images travel as refs, never bytes).
    MAX_BODY_BYTES = 1_000_000
    # A request's deadline (see #handle_post_turn) that isn't epoch seconds.
    BAD_DEADLINE = [{ "Allow" => "POST" }, 400, { error: "bad_deadline", detail: "deadline must be epoch seconds" }].freeze
    # The request header that names the Bridge's secret, lowercased as #read_request keeps it.
    SECRET_HEADER = BridgeSecret::HEADER.downcase
    # Bytes of randomness in a Bridge's secret (hex in bridge.json: twice as many characters).
    SECRET_BYTES = 32
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
    # @param on_command [#call, nil] takes a session command, returns its
    #   mid-turn policy (:anytime when it runs now)
    #   ({command_id:, client_id:, line:}) for the worker loop to run; without
    #   one, POST /command answers 501
    # @param on_exit_request [#call, nil] a client asks the worker to exit
    #   now: takes the client_id and delete: (the exit is to delete the
    #   session, /exit --delete) or stop: ("all": stop everything the user
    #   can stop first), returns nil when the worker will leave or
    #   what keeps it up (a WorkerIdleExit::Hold: #reason, #tasks, #hint,
    #   #holds); called with the event log held. Without one, POST /exit
    #   answers 501
    # @param exit_discards [#call, nil] after an exit the worker agreed to:
    #   whether it will delete the session as empty (the 200 says
    #   +discard+); without one the reply leaves the field out
    # @param exit_stopped [#call, nil] after a stop-all exit: what it stopped
    #   (a HoldStop::Stopped) for the 200's +stopped+; nil leaves it out
    # @param on_holds [#call, nil] what the user could stop in this worker
    #   right now (WorkerIdleExit#stoppable_holds) for GET /holds; without
    #   one that route answers 501
    # @param on_holds_stop [#call, nil] stop every one of them (HoldStop#stop_all)
    #   without the worker exiting, for POST /holds/stop; returns the
    #   HoldStop::Stopped the 200's +stopped+ carries; without one that route
    #   answers 501
    def initialize(engine:, state_dir:, session_id:, bind: DEFAULT_BIND,
                   port: 0, ring_capacity: DEFAULT_RING_CAPACITY,
                   heartbeat_interval: DEFAULT_HEARTBEAT_INTERVAL, input_format: nil, on_input: nil,
                   on_command: nil, on_exit_request: nil, exit_discards: nil, exit_stopped: nil,
                   on_holds: nil, on_holds_stop: nil)
      @engine = engine
      @on_input = on_input
      @on_command = on_command
      @on_exit_request = on_exit_request
      @exit_discards = exit_discards
      @exit_stopped = exit_stopped
      @on_holds = on_holds
      @on_holds_stop = on_holds_stop
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
      # Only in bridge.json (0600) and this process: never logged, never in an
      # event, a reply or the session's files.
      @secret = SecureRandom.hex(SECRET_BYTES)

      @capture_handle = nil
      @server = nil
      @accept_thread = nil
      @connection_threads = []
      @stopped = false
      @mutex = Monitor.new
      @refused_log_mutex = Mutex.new
      @refused_logged_at = {}
      @open_streams = 0
      # Open streams by the client_id a stream named (`?client_id=`); web
      # tabs, through the `chi web` proxy, name none.
      @streams_by_client = Hash.new(0)
      @last_client_activity_at = monotonic_now
    end

    # The secret never shows in an inspect (a log line, an error's message).
    def inspect = "#<#{self.class.name} session_id=#{@session_id.inspect} port=#{@port}>"
    alias to_s inspect

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
      # #stop and #close_intake wake the acceptor through it: closing the
      # listen socket doesn't cut a select on it short on Linux.
      @wake_reader, @wake_writer = IO.pipe
      @accept_thread = Thread.new { accept_loop }
      @accept_thread.report_on_exception = false
      write_sidecar
      self
    rescue StandardError => e
      stop
      raise e
    end

    # Raised on a connection thread whose request would queue something
    # (a turn, a command, an exit) after #close_intake: the connection
    # closes unanswered, as #stop's kill of a request still waiting did.
    class IntakeClosed < StandardError; end

    # With the event log held (the worker leaving: Worker#leave_idle,
    # #leave_on_request): no connection is accepted and no request queues
    # a turn, a command or an exit from here on. #stop, called once the log
    # is let go, does the rest: a request that waited on the log then ends
    # at once instead of holding #stop for its REQUEST_GRACE_SECONDS.
    def close_intake
      @mutex.synchronize { @stopped = true }
      begin
        @server&.close
      rescue StandardError
        nil
      end
      wake_acceptor
    end

    # Stop the acceptor, release the socket and remove the sidecar, so clients
    # don't have to find it stale. Does not stop the owning turn. Joins the
    # acceptor thread so the process can exit cleanly (Ruby waits for a thread
    # blocked in IO.select at VM shutdown). Safe to call again.
    #
    # The sidecar goes before the open streams close: a client that
    # reconnects as its stream ends (chi web's proxy, an attached TUI) then
    # finds no worker, or the next one, never this one's dead port.
    def stop
      @mutex.synchronize { @stopped = true }
      begin
        @server&.close
      rescue StandardError
        nil
      end
      wake_acceptor
      @capture_handle&.unsubscribe
      @accumulator_handle&.unsubscribe
      @engine.running_turn_messages = nil
      @cards_handle&.unsubscribe
      @pending_card_handle&.unsubscribe
      @pending_card&.clear
      # A turn post killed between its enqueue and its reply looks failed to
      # the web, which then queues the prompt again from the input file.
      await_answers(REQUEST_GRACE_SECONDS)
      remove_sidecar
      @connection_threads.each { |t| t.kill rescue nil }
      @connection_threads.clear
      # Its relay watchers (RelayWatcher) end with it.
      watchers = @mutex.synchronize { (@relay_watchers || []).tap { @relay_watchers = [] } }
      watchers.each { |thread| thread.kill.join(RELAY_WATCHER_JOIN_SECONDS) }
      @accept_thread&.join(2)
      [@wake_reader, @wake_writer].each { |io| io&.close rescue nil }
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
    # The commands queued for after the running turn (queued_commands,
    # TurnAccumulator#queued_commands) too.
    # working_set: the running turn's last :working_set_updated ({items:,
    # at:}, TurnAccumulator#working_set), which the messages lag; nil
    # between turns and before the turn emitted one.
    # @return [Hash] {messages:, current_turn:, working_set:, queued:, queued_commands:, recap:, saved_recap:, continue_offer:, pending_question:,
    #   guardrail_warning:, plugin_warning:, init_tasks:, cards:, commands:, chi_version:, event_seq:, event_id:}
    def snapshot
      @engine.synchronize_events do
        seq = @engine.event_count
        {
          messages: @engine.messages_checkpoint,
          current_turn: current_turn_with_generation,
          working_set: @accumulator.working_set,
          queued: @accumulator.queued,
          queued_commands: @accumulator.queued_commands,
          recap: @accumulator.recap,
          saved_recap: @engine.saved_recap,
          continue_offer: @accumulator.continue_offer,
          pending_question: @engine.pending_question&.to_h,
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
    # The session's folder (working_directory) rides along: what the web
    # checks the answer's file refs against without reading the session file.
    # @return [Hash] {session_id:, working_directory:, session_state_snapshot:, answer:, cards:, event_seq:, event_id:}
    # +turn_id+: that turn's answer, not the newest (Engine#last_answer_message).
    def tail_frame(turn_id: nil)
      @engine.synchronize_events do
        seq = @engine.event_count
        state = @engine.session_state_snapshot.merge(event_seq: seq, event_id: event_id(seq))
        { session_id: @session_id, working_directory: @engine.session&.working_directory,
          session_state_snapshot: state, answer: @engine.last_answer_message(turn_id: turn_id),
          cards: @cards.list, event_seq: seq, event_id: event_id(seq) }
      end
    end

    # The worker's own way in for a session command that came as a message
    # (its first prompt, an input file): queued and announced as a POST
    # /command's is (#handle_command).
    # @param after_file [String, nil] the input file it came in (its
    #   basename): it runs once that file is taken (Worker#on_command)
    # @return [String] its command_id
    def queue_command(line, client_id: nil, card: false, after_file: nil, enqueued_id: nil, author: nil)
      # A card's action (the step-limit question's answer): the UIs leave
      # its line out. +enqueued_id+: a file-delivered command's input, whose
      # sender's wait its command_ran settles. +author+: its input's.
      command = QueuedCommand.mint(line.to_s.strip, client_id: client_id, card: card, author: author)
                             .with(enqueued_id: enqueued_id)
      @engine.synchronize_events { queue_command_locked(command, after_file: after_file) }
      command.command_id
    end

    private

    # The turn in progress (TurnAccumulator#current_turn) with the running
    # generation's phase as generation: {thinking_only:, age:}
    # (Engine#generation_snapshot), so a page joining mid-generation can
    # clock its delivery line and say whether a cut can land.
    def current_turn_with_generation
      turn = @accumulator.current_turn
      gen = turn && @engine.generation_snapshot
      gen ? turn.merge(generation: gen.to_h) : turn
    end

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

    # #stop or #close_intake: the acceptor's select returns now.
    def wake_acceptor
      @wake_writer&.write_nonblock(".", exception: false)
    rescue IOError
      nil # closed by an earlier #stop
    end

    def accept_loop
      loop do
        break if stopped? || @server.closed?

        begin
          rs, = IO.select([@server, @wake_reader], nil, nil, 0.5)
        rescue IOError
          break
        end

        next unless rs
        break if rs.include?(@wake_reader)

        client =
          begin
            @server.accept
          rescue IOError, Errno::EBADF
            break
          end

        Thread.new { handle_connection(client) }.tap do |t|
          t.report_on_exception = false
          # The ended connections' threads go as a new one comes, so a
          # long-lived worker's list holds its open connections only. A new
          # Array: #await_answers and #stop may be walking the old one.
          @connection_threads = @connection_threads.select(&:alive?) << t
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
        # A refusal closes the connection, as its Connection: close says: a
        # client that asked to keep it open (a stream's keep-alive) reads
        # the refusal to its end at once rather than waiting.
        elsif browser_request?(headers)
          write_json(io, 403, nil, { error: "cross_origin", detail: "the bridge answers chi's own clients only" })
          break
        elsif proxied_request?(headers)
          note_refused(:proxied, "proxied_refused", request[:path])
          write_json(io, 403, nil, { error: "proxied", detail: "the bridge answers chi's own clients on this machine, " \
                                                               "never a request through a proxy" })
          break
        elsif !secret_ok?(headers)
          note_refused(:secret, "secret_refused", request[:path])
          write_json(io, 403, nil, { error: BridgeSecret::ERROR, detail: BridgeSecret.refused(@session_id) })
          break
        # From here on a client of this worker (it named the secret): only its
        # requests keep the worker from its idle exit, never a refused one's
        # (an older chi web's polls, a scan through a forward).
        elsif route.nil?
          note_client_activity
          write_json(io, 404, { "Allow" => "GET, POST" },
                     { error: "not_found", path: request[:path] })
        elsif route.first == :stream
          note_client_activity
          cursor = reconnect_cursor(headers, request[:query])
          Log.debug(:bridge, "stream", method: method, path: request[:path], client_id: stream_client_id(request[:query]))
          serve_sse(io, route.last, last_event_id: cursor, snapshot: snapshot_requested?(request[:query]),
                                    client_id: stream_client_id(request[:query]), raw: raw_requested?(request[:query]))
          break # SSE owns the connection until the client disconnects.
        else
          note_client_activity
          payload, status, body = dispatch(route.first, route.last, request[:body], request[:query])
          write_json(io, status, payload, body)
        end

        Thread.current[:bridge_answering] = false
        log_request(method, request[:path], started)
        break if close_after_request?(headers)
      end
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError, IntakeClosed
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
    def serve_sse(io, session_id, last_event_id:, snapshot: false, client_id: nil, raw: false)
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
        heartbeat_interval: @heartbeat_interval,
        raw: raw
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
    # A request through a proxy (an auth proxy forwarding every port, as a
    # work pod's does) carries a trace chi's own clients never send
    # (ProxyTrace: X-Forwarded-*, Forwarded, X-Real-IP, X-Auth-Request-*…,
    # underscore twins too): refused, whoever signed in to the proxy. chi
    # web's stream proxy forwards Last-Event-ID only (ProxyStreamBody).
    def proxied_request?(headers) = headers.keys.any? { |name| ProxyTrace.header?(name) }

    REFUSED_LOG_INTERVAL = 60.0

    # Whether the request names this Bridge's secret (SECRET_HEADER), compared
    # in constant time. Every route asks for it, the stream and the read-only
    # ones too: what they show is the session itself.
    def secret_ok?(headers)
      given = headers[SECRET_HEADER]
      given.is_a?(String) && OpenSSL.secure_compare(given, @secret)
    end

    # A refusal's log line, at most once a minute per +kind+: a scan through
    # a forward, or an old chi web's every poll, would fill the log. The path
    # only, never a header.
    def note_refused(kind, event, path)
      now = monotonic_now
      due = @refused_log_mutex.synchronize do
        last = @refused_logged_at[kind]
        (last.nil? || now - last >= REFUSED_LOG_INTERVAL).tap { |fresh| @refused_logged_at[kind] = now if fresh }
      end
      Log.warn(:bridge, event, path: path) if due
    end

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
    # task_stop: POST tasks/stop (#handle_task_stop), the web's stop-task button.
    # reparent: the worker reads Session::PARENT_FILE (its rings, each turn's
    # start), so a continue may move it to the chain's new link (ChildMove).
    # delivery: POST /turn runs every Delivery value; a queue waits for the
    # turn's end (Delivery::QUEUE_FEATURE). A worker without it would steer.
    # turn_ids: the running turn's checkpoint mark, a continue turn and a
    # Stop's last_turn carry the turn's enqueued_id (ReplyWait.own_turn).
    # unqueue: POST turn/dequeue (#handle_dequeue_turn) takes a queued
    # message back before it runs.
    # review_turns: a participant's turn runs as its own, inside the review
    # boundary (Guardrails::ReviewBoundary); a worker without it has none,
    # so chi web sends it no participant's turn (Delivery::REVIEW_FEATURE).
    # pair_turns: a participant's turn in a working session runs as a pair
    # turn (Guardrails::PairBoundary); a worker without it runs it as a
    # review turn, and chi web says so (Delivery::PAIR_FEATURE).
    FEATURES = ["restart", "task_stop", "reparent", Delivery::QUEUE_FEATURE, ReplyWait::TURN_IDS_FEATURE,
                VerifyAnchor::FEATURE, ReviseAnchor::FEATURE,
                SessionInbox::UNQUEUE_FEATURE, Delivery::REVIEW_FEATURE, Delivery::PAIR_FEATURE].freeze

    # The routes, by method and what follows /session/:id/: a handler takes
    # the session id and the request body and returns [headers, status, body].
    # GET stream is served apart (#serve_sse owns the connection).
    ROUTES = {
      %w[GET stream] => :stream,
      %w[POST cancel] => :handle_cancel,
      %w[POST answer] => :handle_answer,
      %w[POST question/dismiss] => :handle_dismiss_question,
      %w[POST guardrails/wrong] => :handle_system_one_wrong,
      %w[POST turn] => :handle_post_turn,
      %w[POST turn/dequeue] => :handle_dequeue_turn,
      %w[POST command] => :handle_command,
      %w[POST exit] => :handle_exit_request,
      %w[GET holds] => :handle_holds,
      %w[POST holds/stop] => :handle_holds_stop,
      %w[POST recap] => :handle_recap,
      %w[POST relay] => :handle_relay,
      %w[POST relay/status] => :handle_relay_status,
      %w[POST tasks/stop] => :handle_task_stop,
      %w[GET state] => :handle_state,
      %w[GET stats] => :handle_stats,
      %w[GET snapshot] => :handle_snapshot,
      %w[GET tail] => :handle_tail
    }.freeze
    ROUTE_PATH = %r{\A/session/([^/]+)/(.+)\z}u

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
    # 200 {enabled:, saved:, request:, min_user_turns:}; off, session_off:
    # whether the session's own setting (/recap off) turned it off.
    # Returns [headers, status, body].
    def handle_recap(_session_id, _body = nil)
      recap = @engine.recap
      return [{}, 200, { enabled: false, session_off: @engine.recap_override == false }] unless recap

      saved = @engine.saved_recap
      [{}, 200, { enabled: true, saved: saved, request: @engine.request_recap.to_s, min_user_turns: recap.min_user_turns }]
    end

    # Cancel the active turn on this session's engine, if any.
    # Returns [headers, status, body].
    def handle_cancel(_session_id, body)
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

    # POST /session/:id/tasks/stop {task_id}: stop a background task as the
    # user (TaskRuntime.stop_task by: "user"); a task_wait on it returns, and
    # the turn goes on. Only a task this conversation created: records in
    # tmp/tasks are shared by every session in the cwd. Those are in the
    # saved conversation, or, created in the running turn, only in the
    # accumulator's task_create parts. 200 {status, stop_reason, task_id},
    # 404 task_not_found, 409 not_running (it already ended), 400 no id.
    # Answers once the task is gone: up to STOP_GRACE_SEC.
    def handle_task_stop(_session_id, body)
      parsed = parse_json(body)
      task_id = (fetched(parsed, "task_id") if parsed.is_a?(Hash)).to_s.strip
      return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "task_id required" }] if task_id.empty?
      return [{}, 404, { error: "task_not_found", task_id: task_id }] unless own_task_ids.include?(task_id)

      record, error = Tools::TaskRuntime.get_record(task_id)
      return [{}, 404, { error: "task_not_found", task_id: task_id }] if error
      return [{}, 409, { error: "not_running", status: record.status, task_id: task_id }] unless record.running?

      Log.info(:bridge, "task_stop", task_id: task_id)
      record, error = Tools::TaskRuntime.stop_task(task_id, by: "user")
      return [{}, 500, { error: "bridge_error", detail: error }] if error

      [{}, 200, { status: record.status, stop_reason: record.stop_reason, task_id: task_id }]
    end

    # The tasks this session started: its history's (created_ids_in) and
    # this turn's rows, a task_create's or an execute handed over at its
    # limit (only after its HANDED_OVER line: its output can print a
    # "task_id:" line of its own).
    def own_task_ids
      running = Array(@accumulator.current_turn&.dig(:parts)).filter_map do |part|
        Tools::TaskRuntime.created_id(part[:tool], part[:output]) if part[:kind] == "tool"
      end
      Tools::TaskRuntime.created_ids_in(@engine.messages_checkpoint) | running
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
      # Guardrails::ParentPolicy (QuestionDesk::Refused). Not a boundary:
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
        [{}, 200, { status: "answered", session_id: session_id, answer: result.to_h }]
      rescue Engine::QuestionNotPending => e
        # Another client answered first, or the question was cancelled.
        [{}, 409, { error: "question_not_pending", detail: e.message }]
      rescue QuestionDesk::Refused => e
        Log.info(:bridge, "parent_answer_refused", sid: session_id, id: qid, reason: e.reason)
        [{}, 403, { error: "parent_answer_refused", reason: e.reason.to_s, detail: e.detail }]
      rescue ArgumentError => e
        [{}, 400, { error: "invalid_answer", detail: e.message }]
      end
    end

    # POST /session/:id/guardrails/wrong {id}: append a false-allow label
    # only for this session's System 1 auto-allow. Unknown ids are not
    # distinguishable from judgments belonging to another session.
    def handle_system_one_wrong(session_id, body)
      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      judgment_id = fetched(parsed, "id").to_s.strip
      return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "id required" }] if judgment_id.empty?

      log = SystemOne::Log.new(dir: Guardrails::Approvals.dir_for(@state_dir))
      entry = log.entries.find do |judgment|
        judgment["id"] == judgment_id &&
          judgment["session_id"] == session_id &&
          judgment["decision"] == "auto"
      end
      return [{}, 404, { error: "unknown_judgment" }] unless entry
      return [{}, 200, { status: "labelled", id: judgment_id }] if entry["answer"] == "should_have_asked"
      return [{}, 409, { error: "already_labelled" }] unless entry["answer"].nil?
      return [{}, 500, { error: "label_failed", detail: "could not write the System 1 label" }] unless log.label(judgment_id, "should_have_asked")

      [{}, 200, { status: "labelled", id: judgment_id }]
    end

    # What a parent's relay may say about this session's approval
    # (BridgeClient#relay): opened and closed only change how the question
    # shows (QuestionDesk#annotate); answered makes this worker ask the
    # parent for the answer (RelayVerifier). Like every Bridge route, this
    # request requires the Bridge's secret.
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
    # status, body]: 202 with its command_id, or 408. +author+: a POST
    # /turn's (a /word sent as a message).
    def queue_command_request(session_id, line, client_id:, deadline: nil, card: false, author: nil)
      # A card's action: the UIs leave its line out (the card is the echo).
      command = QueuedCommand.mint(line, client_id: client_id, card: card, author: author)
      queued = @engine.synchronize_events do
        raise IntakeClosed if stopped?
        next false if expired?("command_expired", deadline, sid: session_id, client_id: command.client_id)

        queue_command_locked(command)
        true
      end
      return deadline_passed("command") unless queued

      [{}, 202, { status: "accepted", command_id: command.command_id, session_id: @session_id }]
    end

    # With the event log held. +on_command+ answers what it did with the
    # line (Commands::Registry::MID_TURN).
    def queue_command_locked(command, after_file: nil)
      policy = after_file ? @on_command.call(command, after_file: after_file) : @on_command.call(command)
      # An anytime command runs now, beside a turn (D8): the UIs show its
      # line here, so the cards it shows come after it. A queued one runs
      # when the turn ends: the UIs show it waiting until its command_ran.
      marks = case policy
              when :anytime then { anytime: true }
              when :queue then { waits: "turn_end" }
              else {}
              end
      @engine.announce(type: :command_queued, **command.event_fields, **marks)
    end

    # A client asks the worker to exit now (`/exit` in the attached TUI), or
    # with "restart": true to hand the session to a new worker on the newest
    # chi installed (the "restart" feature). "stop": "all" first stops every
    # hold the user can stop; "ask": false leaves the delegate children out of
    # the list (a UI that can't ask about them, as /archive). The worker
    # decides with the event log held, so no POST /turn lands between its
    # check and its answer; it leaves from its loop after this reply.
    # 200 {status: "exiting", discard?: the session is empty and goes,
    # stopped?: what a "stop": "all" exit stopped} ({status: "restarting"} for
    # a restart), or 409 {status: "held", reason:} naming what keeps it up
    # (with tasks: [{id:, command:, age_seconds:}] and a hint: how to stop
    # them, for background_tasks). When every hold is one the user can stop,
    # the 409 also carries holds: [{kind:, items: [{id:, label:, detail:}]}
    # — reminders, running tasks, delegate children — for the terminal's ask.
    # A past +deadline+ (see #handle_post_turn), checked with the event log
    # held: 408 deadline_passed, the worker not asked (its client said it
    # didn't stop).
    # Returns [headers, status, body].
    def handle_exit_request(session_id, body)
      return [{}, 501, { error: "exit_unavailable" }] unless @on_exit_request

      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      client_id = fetched(parsed, "client_id")
      delete = fetched(parsed, "delete") == true
      restart = fetched(parsed, "restart") == true
      stop_all = fetched(parsed, "stop") == "all"
      # A client that can ask about what still runs (an attached terminal's
      # plain /exit) gets the delegates in the hold list; one that can't
      # (/archive, and every worker's own last look) does not.
      options = restart ? { delete: delete, restart: true } : { delete: delete }
      options[:stop] = true if stop_all && !restart
      options[:ask] = false if fetched(parsed, "ask") == false
      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      hold = @engine.synchronize_events do
        raise IntakeClosed if stopped?
        next :expired if expired?("exit_expired", deadline, sid: session_id, client_id: client_id)

        @on_exit_request.call(client_id, **options)
      end
      return deadline_passed("exit request") if hold == :expired

      if hold.nil?
        return [{}, 200, { status: "restarting", session_id: @session_id }] if restart

        body = { status: "exiting", session_id: @session_id }
        body[:discard] = @exit_discards.call == true if @exit_discards
        stopped = @exit_stopped&.call
        body[:stopped] = stopped.to_h if stopped
        return [{}, 200, body]
      end

      # A hold may name what it waits for (tasks: the background tasks a
      # finish wake watches). When every hold is one the user can stop, +holds+
      # lists them for the terminal's ask: [{kind:, items: [{id:, label:,
      # detail:}]} (docs/cli.md, /exit).
      [{}, 409, { status: "held", reason: hold.reason.to_s, tasks: hold.tasks, hint: hold.hint,
                  holds: holds_json(hold.holds), session_id: @session_id }.compact]
    end

    # The exit ask's stoppable holds as JSON; nil when there are none, so an
    # older client sees today's plain 409.
    def holds_json(holds)
      return nil if holds.nil? || holds.empty?

      holds.map { |hold| { kind: hold.kind.to_s, items: hold.items.map { |item| item.to_h } } }
    end

    # GET /session/:id/holds: what the user could stop in this worker right
    # now — the same holds the exit ask's 409 carries (reminders, the watched
    # background tasks still running, the delegate children with a live
    # worker), whatever else keeps the worker up: chi web's Stop asks about
    # these before it TERMs the worker, and a Stop cancels a running turn
    # anyway, so a turn is not a reason to hide them.
    # 200 {session_id, holds: [{kind:, items: [...]}]} (no +holds+ when there
    # are none); 501 holds_unavailable when this worker has no such step.
    # Returns [headers, status, body].
    def handle_holds(_session_id, _body = nil)
      return [{}, 501, { error: "holds_unavailable" }] unless @on_holds

      [{}, 200, { session_id: @session_id, holds: holds_json(@on_holds.call) }.compact]
    end

    # POST /session/:id/holds/stop: stop everything the user can stop (HoldStop#stop_all)
    # without the worker leaving — the reminders cleared, the watched tasks
    # killed as task_stop does, the delegate children stopped as
    # `chi sessions stop` does. What the user can't stop (a turn running,
    # another UI attached) is untouched. The web's Stop's "Stop all" runs
    # this, then stops the worker.
    # 200 {status: "stopped", session_id, stopped: {reminders:, tasks:,
    # delegates:}}; 501 holds_unavailable when this worker has no such step.
    # Returns [headers, status, body].
    def handle_holds_stop(_session_id, _body = nil)
      return [{}, 501, { error: "holds_unavailable" }] unless @on_holds_stop

      Log.info(:bridge, "holds_stop")
      stopped = @on_holds_stop.call
      [{}, 200, { status: "stopped", session_id: @session_id, stopped: stopped.to_h }]
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
    def handle_post_turn(_session_id, body)
      parsed = parse_json(body)
      unless parsed.is_a?(Hash)
        return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }]
      end

      sid = fetched(parsed, "session_id")
      prompt = fetched(parsed, "prompt")
      client_id = fetched(parsed, "client_id")
      # --no-interrupt: the turn runs with the raised iteration limit.
      no_interrupt = fetched(parsed, "no_interrupt") == true
      # Who wrote it when it isn't the owner (chi web stamps it from the
      # request's principal; the Bridge is loopback and trusts its caller).
      author = fetched(parsed, "author")
      author = nil unless author.is_a?(String) && !author.empty?
      # A Verify turn's claim, a Revise turn's draft; a participant can't
      # Revise (chi web drops it first, this is the worker's own layer).
      anchors = TurnAnchors.from(parsed)
      anchors = anchors.without_revises if Steer.participant_author?(author)
      if sid.to_s.strip.empty? || prompt.to_s.strip.empty?
        return [{ "Allow" => "POST" }, 400,
                { error: "missing_fields", detail: "session_id and prompt are required" }]
      end
      return [{}, 404, { error: "unknown_session" }] unless own_session?(sid)

      images = ImageStore.check_refs(session_dir, fetched(parsed, "images"))
      return [{}, 400, { error: "bad_images", detail: images }] if images.is_a?(String)

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      raw_delivery = fetched(parsed, "delivery")
      if (refused = Delivery.refusal(raw_delivery))
        return [{ "Allow" => "POST" }, 400, refused]
      end

      delivery = Delivery.parse(raw_delivery)
      # How many of a participant's turns may be running or waiting
      # (chi web's, from their grant: its queue limit plus the running one).
      pending_limit = nil
      if Steer.participant_author?(author)
        # A participant's message is a turn of its own, whatever the body
        # asks (D6), and never a command or a shell line: chi web refuses
        # those first, and this is the worker's own layer.
        return participant_refused(sid, author, "command") if command_registry.command?(prompt.to_s)

        delivery = Delivery::QUEUE
        pending_limit = fetched(parsed, "pending_limit")
        pending_limit = nil unless pending_limit.is_a?(Integer) && pending_limit.positive?
      end
      # A Verify or Revise turn is a turn of its own too (the worker holds
      # it for the turn's end, SessionInbox.turn_end_data?): never a cut,
      # and the ack and :turn_enqueued say it queues behind a running turn.
      delivery = Delivery::QUEUE unless anchors.empty?

      # A session command sent as a message (chi send -m "/model x", chi -p,
      # a UI whose command list lags) runs as the command, as typed in a
      # TUI; an unknown /word stays a prompt. Not with images: those are
      # for the model.
      if images.empty? && @on_command && command_registry.command?(prompt.to_s)
        return queue_command_request(sid, prompt.to_s.strip, client_id: client_id, deadline: deadline, author: author)
      end

      enqueued_id = SecureRandom.uuid
      # Before it is queued: a drain after this may have taken it (#cut_for_steer).
      epoch = @engine.input_epoch
      # Whether a queue waits for a running turn: read with the write under
      # the event log, so no :turn_started or :turn_completed falls between.
      # To an idle worker the queued file simply runs as the next turn.
      queued_behind_turn = false
      # Write and announce with the event log held: the worker can't emit
      # this turn's :turn_started (or merge it mid-turn) before
      # :turn_enqueued, and a failed write announces nothing.
      enqueued = @engine.synchronize_events do
        raise IntakeClosed if stopped?
        next :expired if expired?("turn_expired", deadline, sid: sid, client_id: client_id)
        next :too_many if pending_limit && pending_turns(author) >= pending_limit

        # The owner's input never goes into a participant's read-only
        # review turn (a steer, a cut): it queues behind it as the owner's
        # own turn, and the ack and :turn_enqueued say so.
        delivery = Delivery::QUEUE if @accumulator.participant_turn?
        queued_behind_turn = Delivery.queue?(delivery) && !@accumulator.current_turn.nil?
        enqueue_turn(prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                     no_interrupt: no_interrupt, images: images, delivery: delivery, author: author, anchors: anchors).tap do |ok|
          next unless ok

          enqueued_event = { type: :turn_enqueued, enqueued_id: enqueued_id, client_id: client_id, prompt: prompt.to_s }
          enqueued_event[:images] = images unless images.empty?
          enqueued_event[:delivery] = Delivery::QUEUE if queued_behind_turn
          enqueued_event[:author] = author if author
          @engine.announce(enqueued_event)
          @on_input&.call
        end
      end
      return deadline_passed("turn") if enqueued == :expired
      return [{}, 429, { error: "too_many_turns", detail: ParticipantMessages::TOO_MANY_TURNS }] if enqueued == :too_many
      return [{}, 500, { error: "enqueue_failed", detail: "could not write turn input" }] unless enqueued

      # Queued (outside the event lock): a message sent as +cut+ cuts a
      # running generation that has only been thinking for long, unless a
      # plugin or a client chi doesn't know sent it. An image input never
      # merges mid-turn, so it never cuts. Nothing else cuts: a message
      # that says nothing (an older client, the web composer) goes in at
      # the running turn's next step.
      cut = nil
      cut = @engine.cut_for_steer(Steer.source_for_client(client_id), epoch: epoch) if images.empty? && Delivery.cut?(delivery)
      # A queue to an idle worker is a turn now: the ack says next_step.
      ack_delivery = Delivery.queue?(delivery) && !queued_behind_turn ? Delivery::NEXT_STEP : delivery
      ack = { status: "accepted", enqueued_id: enqueued_id, session_id: @session_id, delivery: ack_delivery }
      ack[:cut] = cut.to_s if cut
      ack[:cut_after] = @engine.steer_cut_after if cut == :waits
      [{}, 202, ack]
    end

    # POST /session/:id/turn/dequeue {enqueued_id, client_id?, deadline?}:
    # take back a queued message (one that waits for the running turn's
    # end: a queue or an image message) before a turn takes it. With the
    # event log held, as its enqueue was, so :turn_dequeued always follows
    # its :turn_enqueued; the file is claimed as the drain claims it (one
    # rename wins), deleted, and its tombstone left for a wait on its turn
    # (SessionInbox.take_queued_input). It never wakes the worker.
    # 200 {status: "removed", enqueued_id, prompt}; 409 already_started (a
    # turn took it, or the snapshot still lists it with no file left: taken,
    # not announced yet), 409 not_queued (a next-step message: a drain may
    # merge it any moment); 404 unknown_enqueued_id (never not_found: that is
    # the unrouted path's, what a worker older than the route answers);
    # 408 past its +deadline+ (see #handle_post_turn), nothing removed.
    def handle_dequeue_turn(session_id, body)
      parsed = parse_json(body)
      return [{ "Allow" => "POST" }, 400, { error: "invalid_json" }] unless parsed.is_a?(Hash)

      id = fetched(parsed, "enqueued_id").to_s.strip
      return [{ "Allow" => "POST" }, 400, { error: "missing_fields", detail: "enqueued_id required" }] if id.empty?

      deadline = fetched(parsed, "deadline")
      return BAD_DEADLINE unless deadline_valid?(deadline)

      client_id = fetched(parsed, "client_id")
      taken, input = @engine.synchronize_events do
        raise IntakeClosed if stopped?
        next [:expired, nil] if expired?("dequeue_expired", deadline, sid: session_id, enqueued_id: id)

        SessionInbox.take_queued_input(session_dir, id).tap do |status, _|
          @engine.announce(type: :turn_dequeued, enqueued_id: id, client_id: client_id) if status == :removed
        end
      end
      dequeue_reply(taken, id, input)
    end

    # +author+'s turns running or waiting: the running turn when it is
    # theirs, and their queued ones. Read with the event log held.
    def pending_turns(author)
      running = TurnOrigin.of(@accumulator.current_turn&.dig(:origin)).participant_author == author ? 1 : 0
      running + @accumulator.queued.count { |row| row[:author] == author }
    end

    # 403 not_permitted for a participant's +what+ (a command, a shell
    # line), with its audit line.
    def participant_refused(sid, author, what)
      Participants.log(sid, :refused, state_dir: File.dirname(session_dir), participant: Steer.participant_id(author), what: what,
                                      reason: "not_permitted")
      [{}, 403, { error: "not_permitted", detail: Participants::NOT_PERMITTED }]
    end

    def dequeue_reply(taken, id, input)
      case taken
      when :removed then [{}, 200, { status: "removed", enqueued_id: id, prompt: input.prompt.to_s, session_id: @session_id }]
      when :expired then deadline_passed("removal")
      when :not_queued
        [{}, 409, { error: "not_queued", detail: "only a message queued for after the turn can be removed", enqueued_id: id }]
      when :claimed then [{}, 409, { error: "already_started", enqueued_id: id }]
      else
        return [{}, 409, { error: "already_started", enqueued_id: id }] if @accumulator.queued.any? { |q| q[:enqueued_id] == id }

        [{}, 404, { error: "unknown_enqueued_id", enqueued_id: id }]
      end
    end

    # Read-only snapshot surface. AC #4: too-old reconnects re-derive state
    # from here.
    def handle_state(_session_id, _body = nil)
      state = @engine.session_state_snapshot
      [{}, 200, { session_id: @session_id, session_state_snapshot: state.merge(event_id: event_id(state[:event_seq])) }]
    end

    # /stats for an attached client: the metrics, with the window and prompt
    # profile asked from the server when no turn has reported them yet (so,
    # unlike /state, it may wait on one short /props GET).
    def handle_stats(_session_id, _body = nil)
      [{}, 200, { session_id: @session_id, metrics: @engine.stats_snapshot }]
    end

    # The snapshot frame's content as one request, for a client that renders
    # the messages elsewhere (the web server strips and formats them): it then
    # streams from the snapshot's event_seq, and the ring replays what came
    # after (or the stream resets). Returns [headers, status, body].
    def handle_snapshot(_session_id, _body = nil)
      [{}, 200, snapshot_frame]
    end

    # The page's light re-read (#tail_frame): no message list. `?turn_id=`:
    # that turn's answer (a queued turn's page re-reads late). The one
    # handler that gets the query (#dispatch); an older worker's route
    # ignores it and sends the newest answer.
    def handle_tail(_session_id, _body = nil, query = nil)
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
    def enqueue_turn(prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, images: [], delivery: nil, author: nil,
                     anchors: nil)
      SessionInbox.write_input(session_dir, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                                            no_interrupt: no_interrupt, images: images, delivery: delivery, author: author,
                                            anchors: anchors)
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
        break if ["\r\n", "\n"].include?(line)

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

    # `?raw=1`: events as the engine emitted them (a chunk's provider
    # payload), not as clients get them (ClientEvent). For debugging on the
    # worker's port: chi web never passes it on.
    def raw_requested?(query)
      return false unless query

      URI.decode_www_form(query).to_h["raw"].to_s == "1"
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
    # (RelayVerifier). Read-only; like every Bridge route, it requires the
    # Bridge's secret. 404 for an unknown id.
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
      relay = pending&.relayed_to
      unless pending && pending.id.to_s == qid && relay && (relay[:relay_id] || relay["relay_id"]).to_s == relay_id
        return [{}, 409, { error: "question_not_pending", detail: "no question #{qid} relayed by #{relay_id}" }]
      end
      return [{}, 409, { error: "question_not_pending", detail: "no pending question #{qid}" }] unless @engine.annotate_question(qid, relayed_to: nil, reason: reason)

      Log.info(:bridge, "relay_closed", sid: @session_id, id: qid, reason: reason)
      [{}, 200, { status: "closed", question_id: qid }]
    end

    def write_sidecar
      # version: the chi this worker runs (chi update and the web's badge
      # report older ones); features: what a client may ask of it; epoch:
      # this worker's, as its event ids carry it.
      # secret: what every request must name (#secret_ok?).
      WorkerSidecar.new(port: @port, bind: @bind, session_id: @session_id, started_at: Time.now.iso8601(3),
                        version: Samagotchi::VERSION, input_format: @input_format, features: FEATURES,
                        epoch: @epoch, secret: @secret, pid: Process.pid,
                        protocol: WorkerLink::PROTOCOL).write(session_dir)
    rescue StandardError => e
      Log.warn(:bridge, "sidecar_write_failed", echo: "Bridge: failed to write #{WorkerSidecar::FILE}: #{e.class}: #{e.message}", error: e.class.name)
    end

    # Only while it still carries this bridge's epoch: a racing worker for the
    # same session may have written its own since (a file without an epoch
    # is only ever an older worker's).
    def remove_sidecar
      return unless @server

      File.unlink(WorkerSidecar.path(session_dir)) if WorkerSidecar.read(session_dir)&.epoch == @epoch.to_s
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
