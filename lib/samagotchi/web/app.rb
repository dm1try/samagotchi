# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require "uri"
require "rack"
require "rack/request"

require_relative "../bridge_client"
require_relative "../session"
require_relative "../session_manager"
require_relative "../output_formatter"
require_relative "markdown_renderer"

module Samagotchi
  module Web
    # Rack application that serves the Web UI and JSON API.
    #
    # This is the single-port control plane for Chi Web. It never constructs
    # an Engine directly — it talks to SessionManager over the file IPC layer.
    # Live SSE is proxied from each session's Bridge
    # (the single live client transport); history for any session — including
    # dead ones — is served by GET /api/sessions/:id/output from output/ files.
    class App
      DEFAULT_HOST = BridgeClient::HOST
      BRIDGE_WAIT_TIMEOUT = 10.0

      # @param bridge_wait_timeout [Float] bounded seconds to wait for a
      #   freshly-spawned worker's bridge before answering POST /api/sessions.
      def initialize(manager: nil, session_class: nil, state_dir: nil, public_dir: nil,
                     bridge_wait_timeout: BRIDGE_WAIT_TIMEOUT, markdown: false)
        @manager = manager || SessionManager
        @session_class = session_class || Session
        @state_dir = state_dir
        @public_dir = public_dir || File.expand_path("public", __dir__)
        @bridge_wait_timeout = bridge_wait_timeout
        @markdown_renderer = MarkdownRenderer.new(enabled: markdown)
      end

      def call(env)
        req = Rack::Request.new(env)
        return forbidden unless localhost?(req)

        case [req.request_method, req.path_info]
        when ["GET", "/"], ["GET", "/index.html"]
          serve_index(req)
        when ["GET", "/api/sessions"]
          handle_list(req)
        when ["POST", "/api/sessions"]
          handle_create(req)
        else
          # Dynamic routes
          if (m = %r{\A/api/sessions/([^/]+)/stream\z}.match(req.path_info)) && req.get?
            return handle_stream(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/output\z}.match(req.path_info)) && req.get?
            return handle_output(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/cancel\z}.match(req.path_info)) && req.post?
            return handle_cancel(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/stop\z}.match(req.path_info)) && req.post?
            return handle_stop(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/turn\z}.match(req.path_info)) && req.post?
            return handle_turn(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/answer\z}.match(req.path_info)) && req.post?
            return handle_question_answer(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/question/dismiss\z}.match(req.path_info)) && req.post?
            return handle_question_dismiss(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/command\z}.match(req.path_info)) && req.post?
            return handle_command(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)\z}.match(req.path_info)) && req.get?
            return handle_show(req, m[1])
          end
          if req.path_info.start_with?("/assets/") || req.path_info.start_with?("/public/")
            return serve_static(req)
          end
          # Fallback static file serve from public_dir (e.g. /style.css)
          maybe_static = serve_static(req)
          return maybe_static if maybe_static[0] != 404

          not_found(path: req.path_info)
        end
      rescue StandardError => e
        error_response(500, "internal_error", e.message)
      end

      private

      def localhost?(req)
        # Only 127.0.0.1 / ::1 / localhost are allowed. The socket is bound to
        # 127.0.0.1, but an explicit Host check prevents DNS-rebind tricks.
        host = req.host.to_s.downcase.split(":").first
        %w[127.0.0.1 ::1 localhost].include?(host)
      end

      def forbidden
        error_response(403, "forbidden", "only 127.0.0.1 is allowed")
      end

      def handle_list(req)
        # Lazy retention sweep (once per 24h)
        if @manager.respond_to?(:retention_sweep_if_due)
          begin
            @manager.retention_sweep_if_due(state_dir: @state_dir)
          rescue StandardError
            nil
          end
        end
        sort = sanitize_sort(req.params["sort"])
        order = sanitize_order(req.params["order"])
        limit = sanitize_limit(req.params["limit"])
        offset = sanitize_offset(req.params["offset"])
        sessions = if @state_dir
                     @manager.list_sessions(state_dir: @state_dir, sort: sort, order: order, limit: limit, offset: offset)
                   else
                     @manager.list_sessions(sort: sort, order: order, limit: limit, offset: offset)
                   end
        payload = sessions.map do |s|
          owner = session_owner(s.id)
          session_to_json(s, status: displayed_status(s, owner: owner), owner: owner)
        end
        # Expose total via header for pagination (total unordered count)
        headers = { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store", "Access-Control-Allow-Origin" => "*" }
        # Compute total without limit/offset for header
        if limit || offset.positive?
          total = if @state_dir
                    @manager.list_sessions(state_dir: @state_dir, sort: sort, order: order).size
                  else
                    @manager.list_sessions(sort: sort, order: order).size
                  end
          headers["X-Total-Count"] = total.to_s
        end
        body = JSON.generate(payload)
        headers["Content-Length"] = body.bytesize.to_s
        [200, headers, [body]]
      end

      def sanitize_sort(val)
        %w[created_at updated_at].include?(val.to_s) ? val.to_s : "updated_at"
      end

      def sanitize_order(val)
        %w[asc desc].include?(val.to_s) ? val.to_s : "desc"
      end

      def sanitize_limit(val)
        return nil if val.nil? || val.to_s.strip.empty?
        n = val.to_i
        return nil if n <= 0
        [n, 1000].min
      end

      def sanitize_offset(val)
        return 0 if val.nil? || val.to_s.strip.empty?
        n = val.to_i
        n.positive? ? n : 0
      end

      def handle_create(req)
        body = parse_json(req.body.read)
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        prompt = body["prompt"] || body[:prompt]
        if prompt.to_s.strip.empty?
          return error_response(400, "missing_fields", "prompt is required")
        end
        begin
          session = @manager.spawn_session(prompt: prompt.to_s, state_dir: @state_dir)
        rescue ArgumentError => e
          return error_response(400, "invalid_model", e.message) if e.message.match?(/SAMAGOTCHI_DEFAULT_MODEL/)
          raise
        end
        # The worker's Bridge is the single live transport: wait (bounded) for
        # it so the client can attach without client-side polling.
        json_response(201, session_to_json(session).merge(bridge_port: await_bridge_port(session.id)))
      end

      def handle_show(_req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        history = read_history(id)
        # Read-only preview: selecting a session never spawns a worker.
        # The worker is woken only on POST /turn (handle_turn) via
        # SessionManager.resume_session + write_turn_input. This avoids
        # replaying last_prompt and spamming workers on preview scrub.
        # last_event_seq is nil when no live bridge, so the frontend stays
        # silent until the first Send.
        #
        # A live worker's snapshot is the truth (the session file lags its
        # Engine): the messages, the turn in progress and the prompts queued
        # behind it, all at one event_seq the client streams on from.
        live = bridge_get_json(id, "snapshot")
        turn_snapshot = live && live["snapshot"]
        snapshot = live && live["session_state_snapshot"]
        last_event_seq = snapshot ? snapshot["event_seq"] : bridge_event_seq(id)
        current_turn = turn_snapshot && turn_snapshot["current_turn"]
        pending = if turn_snapshot
                    current_turn && current_turn["pending_question"]
                  elsif session.respond_to?(:pending_question)
                    session.pending_question
                  end
        owner = session_owner(id)
        # A /model in the worker changes it before the file catches up.
        session.model_name = snapshot["model_name"] if snapshot && !snapshot["model_name"].to_s.empty?
        session_json = session_to_json(session, status: displayed_status(session, snapshot, owner: owner), owner: owner)
        # What the worker's server said it served for that model (after a turn).
        if snapshot
          session_json = session_json.merge(served_model: snapshot["served_model"], served_model_for: snapshot["served_model_for"])
        end
        json_response(200, {
          session: session_json,
          history: history,
          messages: messages_for_display(turn_snapshot ? turn_snapshot["messages"] : session.messages),
          current_turn: current_turn,
          queued: turn_snapshot ? Array(turn_snapshot["queued"]) : [],
          recap: turn_snapshot && turn_snapshot["recap"],
          continue_offer: turn_snapshot && turn_snapshot["continue_offer"],
          markdown_warning: @markdown_renderer.warning,
          pending_question: pending,
          last_event_seq: last_event_seq,
          # The stream cursor `<seq>-<epoch>`: a later worker resets it
          # instead of taking the seq as its own. Only the snapshot has it.
          last_event_id: turn_snapshot && turn_snapshot["event_id"],
          timing: timing_payload(id, live_metrics: snapshot && snapshot["metrics"])
        })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def handle_question_answer(req, id)
        session = @session_class.load(id, state_dir: default_state_dir) rescue nil
        return error_response(404, "not_found", "Session not found: #{id}") unless session

        body = parse_json(req.body.read)
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        qid = body["id"] || body[:id] || body["question_id"] || body[:question_id]
        selected = body["selected"] || body[:selected] || body["selection"] || body[:selection]
        freeform = body["freeform"] || body[:freeform] || body["other"] || body[:other]
        # Allow payload nested under answer
        if body["answer"].is_a?(Hash)
          ans = body["answer"]
          qid ||= ans["id"] || ans[:id]
          selected ||= ans["selected"] || ans[:selected]
          freeform ||= ans["freeform"] || ans[:freeform]
        end
        if qid.to_s.strip.empty?
          return error_response(400, "missing_fields", "id is required")
        end
        # Try live Engine via Bridge first (in-process answer without file IPC)
        client = bridge_client(id)
        if client
          begin
            reply = client.answer(id: qid, selected: selected, freeform: freeform)
            return json_response(200, { status: "answered", session_id: id, id: qid }) if reply.ok?

            # Pass the bridge's verdict through: 409 = another client answered
            # first (or the question was cancelled), 400 = invalid selection.
            if [400, 409].include?(reply.status)
              detail = reply.json&.dig("detail") || "answer rejected"
              return error_response(reply.status, reply.status == 409 ? "question_not_pending" : "invalid_answer", detail)
            end
          rescue StandardError
            nil
          end
        end
        error_response(503, "not_live", "no live bridge for session #{id}")
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # Leave the pending question unanswered (the card's Dismiss). A question
      # only exists while its worker waits on it, so this needs a live bridge.
      def handle_question_dismiss(req, id)
        body = parse_json(req.body.read)
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        qid = body["id"].to_s
        return error_response(400, "missing_fields", "id is required") if qid.strip.empty?

        client = bridge_client(id)
        return error_response(503, "not_live", "no live bridge for session #{id}") unless client

        reply = client.dismiss_question(id: qid)
        case reply.status
        when 200 then json_response(200, { status: "dismissed", session_id: id, id: qid })
        when 409 then error_response(409, "question_not_pending", reply.json&.dig("detail") || "question not pending")
        when 404
          error_response(501, "not_supported", "this session's worker runs an older chi: restart it to dismiss questions")
        else error_response(503, "not_live", "no live bridge for session #{id}")
        end
      rescue StandardError
        error_response(503, "not_live", "no live bridge for session #{id}")
      end

      # A session command typed in the composer (/model, /models, !rollback,
      # !cmd, /continue): the worker runs it (woken as for a turn) and every
      # UI gets its :command_ran. Needs the worker's Bridge.
      def handle_command(req, id)
        body = parse_json(req.body.read)
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        line = body["line"].to_s.strip
        return error_response(400, "missing_fields", "line is required") if line.empty?

        @manager.resume_session(id, state_dir: @state_dir) if @manager.respond_to?(:resume_session)
        client = live_bridge_client(id)
        return error_response(503, "not_live", "no live bridge for session #{id}") unless client

        reply = client.post_command(line: line, client_id: body["client_id"])
        case reply.status
        when 202 then json_response(202, reply.json || { status: "accepted" })
        when 400 then error_response(400, reply.json&.dig("error") || "unknown_command", reply.json&.dig("detail") || "not a session command")
        when 404
          error_response(501, "not_supported", "this session's worker runs an older chi: restart it to run commands")
        else error_response(503, "not_live", "no live bridge for session #{id}")
        end
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      rescue SystemCallError, IOError
        error_response(503, "not_live", "no live bridge for session #{id}")
      end

      def handle_output(req, id)
        # Query ?since= may be an ISO8601 time or numeric mtime; we treat it as Time parse.
        since_param = req.params["since"]
        since_time = parse_since(since_param)
        session = @session_class.load(id, state_dir: default_state_dir)
        raw = @manager.read_responses(id, since_time: since_time, state_dir: @state_dir)
        # Strip wire tokens server-side so the client never sees <|tool_call> etc.
        rendered = raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
        json_response(200, { session_id: session.id, output: rendered })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def handle_turn(req, id)
        body = parse_json(req.body.read)
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        prompt = body["prompt"] || body[:prompt]
        client_id = body["client_id"] || body[:client_id]
        if prompt.to_s.strip.empty?
          return error_response(400, "missing_fields", "prompt is required")
        end
        # Ensure session exists and resume worker if needed
        @manager.resume_session(id, state_dir: @state_dir) if @manager.respond_to?(:resume_session)
        # Through the worker's Bridge when it is up, so every live UI sees
        # :turn_enqueued; otherwise straight into the input dir.
        if (client = live_bridge_client(id))
          begin
            reply = client.post_turn(prompt: prompt.to_s, client_id: client_id)
            ack = reply.json
            return json_response(202, ack) if reply.status == 202 && ack.is_a?(Hash)
          rescue SystemCallError, IOError
            nil # the worker closed its Bridge on the way out: queue the file
          end
        end
        enqueued_id = SecureRandom.uuid
        ok = @manager.write_turn_input(id, prompt: prompt.to_s, client_id: client_id, enqueued_id: enqueued_id, state_dir: @state_dir)
        unless ok
          return error_response(500, "enqueue_failed", "could not write turn input")
        end
        owner = session_owner(id)
        # A TUI that took the session between the resume and the write never
        # reads input files; a later worker would replay this one.
        if owner&.fetch("kind", nil) == "tui"
          FileUtils.rm_f(ok) if ok.is_a?(String)
          raise SessionManager::OwnedByTUI, id
        end
        # A worker that idle-exited since the resume never reads it either:
        # wake a new one. (The exiting worker also looks for input it left.)
        if owner.nil? && @manager.respond_to?(:session_owner) && @manager.respond_to?(:resume_session)
          @manager.resume_session(id, state_dir: @state_dir)
        end
        json_response(202, { status: "accepted", enqueued_id: enqueued_id, session_id: id })
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # The session's Bridge, waiting briefly for one a resume just spawned.
      # @return [BridgeClient, nil]
      def live_bridge_client(id)
        port = bridge_sidecar_port(id) || await_bridge_port(id, timeout: [@bridge_wait_timeout.to_f, 5.0].min)
        port && BridgeClient.new(session_id: id, port: port, host: DEFAULT_HOST)
      end

      # The process holding the session: {"pid", "kind" => "worker"|"tui"}, or
      # nil. A worker always runs a Bridge; a TUI (plain `chi`) doesn't share.
      def session_owner(id)
        return nil unless @manager.respond_to?(:session_owner)

        @manager.session_owner(id, state_dir: @state_dir)
      rescue StandardError
        nil
      end

      def handle_cancel(req, id)
        # Validate session exists
        begin
          @session_class.load(id, state_dir: default_state_dir)
        rescue ArgumentError => e
          return error_response(404, "not_found", e.message)
        end

        body = req.body.read
        reason = "user"
        unless body.nil? || body.strip.empty?
          parsed = parse_json(body)
          if parsed.is_a?(Hash)
            r = parsed["reason"] || parsed[:reason] || parsed["cancellation_reason"]
            reason = r.to_s.strip.empty? ? "user" : r.to_s
          end
        end

        # Try direct bridge cancel first (in-process, low latency)
        client = bridge_client(id)
        if client
          begin
            reply = client.cancel(reason: reason)
            if reply.status == 202
              return json_response(202, { status: "cancel_requested", session_id: id, reason: reason, via: "bridge" })
            end
            # The bridge answers 409 when there is no active turn to cancel.
            if reply.status == 409
              return json_response(409, { error: "not_running", detail: "no active turn to cancel", session_id: id })
            end
          rescue StandardError
            nil
          end
        end

        error_response(503, "not_live", "no live bridge for session #{id}")
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def handle_stop(_req, id)
        @manager.stop_session(id, state_dir: @state_dir)
        # Best-effort wait for terminal state (don't block too long for Rack worker)
        if @manager.respond_to?(:wait_for_session)
          @manager.wait_for_session(id, timeout: 2, state_dir: @state_dir)
        end
        json_response(200, { status: "stopped", session_id: id })
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def handle_stream(req, id)
        # Validate session exists
        begin
          @session_class.load(id, state_dir: default_state_dir)
        rescue ArgumentError
          return error_response(404, "not_found", "Session not found: #{id}")
        end

        # Single live transport: proxy to the session's Bridge. When no live
        # worker exists there is nothing to stream — history is available via
        # GET /api/sessions/:id/output.
        bridge_port = bridge_sidecar_port(id)
        # A resume just spawned the worker: its bridge may still be binding.
        # Wait briefly for it so the first SSE connect lands on a live bridge
        # instead of an instantly-closed empty 200 / 503 during startup.
        if bridge_port.nil? && @bridge_wait_timeout.to_i.positive?
          bridge_port = await_bridge_port(id, timeout: [@bridge_wait_timeout.to_f, 2.0].min)
        end
        return error_response(503, "not_live", "no live bridge for session #{id}") unless bridge_port

        headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no",
          "Access-Control-Allow-Origin" => "*"
        }

        # Handlers that buffer enumerable bodies before responding (rackup's
        # WEBrick does `body.each` to completion) hang forever on an unbounded
        # SSE body — the browser never even receives the status line. When the
        # handler supports hijacking, stream frames straight to the socket
        # instead of returning an enumerable.
        if req.env["rack.hijack?"]
          hijack = sse_hijack(id, req, bridge_port)
          return [200, headers.merge("rack.hijack" => hijack), []]
        end

        query = req.query_string.to_s.empty? ? "" : "?#{req.query_string}"
        [200, headers, ProxyStreamBody.new(host: DEFAULT_HOST, port: bridge_port, session_id: id, query: query, headers: req.env)]
      end

      # Rack hijack lambda (env["rack.hijack?"] truthy): pipes the bridge's SSE
      # frames directly to the client socket until it disconnects. The handler
      # (WEBrick via rackup) has already sent the status line + headers, so
      # only body bytes go to the socket here.
      def sse_hijack(id, req, port)
        lambda do |io|
          query = req.query_string.to_s.empty? ? "" : "?#{req.query_string}"
          body = ProxyStreamBody.new(host: DEFAULT_HOST, port: port, session_id: id, query: query, headers: req.env)
          body.each { |chunk| io.write(chunk) }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil # client went away — end the stream quietly
        rescue StandardError
          nil
        end
      end

      # Bounded wait for a freshly-spawned worker's bridge sidecar so the
      # response hands the client a live transport without client-side polling.
      # Returns the bridge port, or nil when it is not up by the deadline (the
      # session still exists; EventSource auto-reconnect covers late binders).
      def await_bridge_port(session_id, timeout: @bridge_wait_timeout)
        return nil if timeout.nil? || timeout <= 0

        BridgeClient.poll(timeout) { bridge_sidecar_port(session_id) }
      rescue StandardError
        nil
      end

      # Port of the session's live Bridge (stale sidecars are removed), or nil.
      def bridge_sidecar_port(session_id)
        dir = @session_class.session_dir(session_id, state_dir: default_state_dir)
        BridgeClient.sidecar_port(dir, host: DEFAULT_HOST)
      rescue StandardError
        nil
      end

      # @return [BridgeClient, nil] a client for the session's live Bridge
      def bridge_client(session_id)
        port = bridge_sidecar_port(session_id)
        port && BridgeClient.new(session_id: session_id, port: port, host: DEFAULT_HOST)
      end

      # Read the live Engine state over the bridge (raw GET /session/:id/state).
      # @return [Hash, nil] parsed JSON body, or nil when no live bridge / timeout.
      def bridge_get_json(session_id, path)
        bridge_client(session_id)&.get_json(path)
      end

      # Monotonic SSE cursor for a live bridge session, else nil.
      def bridge_event_seq(session_id)
        bridge_client(session_id)&.event_seq
      end

      def serve_index(_req)
        path = File.join(@public_dir, "index.html")
        if File.file?(path)
          body = File.read(path)
          [200, {
            "Content-Type" => "text/html; charset=utf-8",
            "Content-Length" => body.bytesize.to_s,
            "Cache-Control" => "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma" => "no-cache",
            "Expires" => "0"
          }, [body]]
        else
          [200, { "Content-Type" => "text/html" }, ["<h1>Chi Web</h1><p>Public dir missing: #{@public_dir}</p>"]]
        end
      end

      def serve_static(req)
        # Serve files under public_dir for /assets/* and bare paths
        rel = req.path_info.sub(%r{\A/(assets|public)/}, "")
        rel = req.path_info.sub(%r{\A/}, "") if rel == req.path_info
        # Prevent directory traversal
        rel = rel.split("/").reject { |p| p == ".." || p.empty? }.join("/")
        full = File.join(@public_dir, rel)
        if File.file?(full) && full.start_with?(@public_dir)
          body = File.binread(full)
          ctype = mime_type(full)
          [200, { "Content-Type" => ctype, "Content-Length" => body.bytesize.to_s, "Cache-Control" => "public, max-age=3600" }, [body]]
        else
          not_found(path: req.path_info)
        end
      end

      def mime_type(path)
        case File.extname(path).downcase
        when ".html" then "text/html; charset=utf-8"
        when ".js" then "application/javascript; charset=utf-8"
        when ".css" then "text/css; charset=utf-8"
        when ".json" then "application/json; charset=utf-8"
        when ".svg" then "image/svg+xml"
        else "application/octet-stream"
        end
      end

      # status is turn state (idle/running). The live worker's snapshot is the
      # truth; on disk, a "running" with no live owner was left by a worker
      # that died mid-turn.
      def displayed_status(session, snapshot = nil, owner: session_owner(session.id))
        return snapshot["status"] if snapshot.is_a?(Hash) && snapshot["status"]
        return session.status unless session.status == Session::STATUS_RUNNING
        return session.status unless @manager.respond_to?(:session_owner)

        owner ? session.status : Session::STATUS_IDLE
      end

      # @param owner [Hash, nil] #session_owner; its kind is shown as `owner`
      def session_to_json(s, status: s.status, owner: nil)
        used = s.respond_to?(:used_memory_names) ? Array(s.used_memory_names) : []
        {
          id: s.id,
          status: status,
          mode: s.mode,
          model_name: s.model_name,
          working_directory: s.working_directory,
          created_at: s.created_at,
          updated_at: s.updated_at,
          last_prompt: s.last_prompt,
          short_id: s.id.to_s[0, 8],
          test_run: !!s.test_run,
          used_memory_names: used,
          first_preview: first_preview_for(s),
          owner: owner&.fetch("kind", nil)
        }
      end

      def timing_payload(session_id, live_metrics: nil)
        persisted = read_analytics(session_id)
        source = if live_metrics.is_a?(Hash)
                   persisted.merge(live_metrics).merge(
                     "started_at" => persisted["started_at"] || live_metrics["started_at"],
                     "turn_records" => merge_timing_records(persisted["turn_records"], live_metrics["turn_records"]),
                     "tool_records" => merge_timing_records(persisted["tool_records"], live_metrics["tool_records"])
                   )
                 else
                   persisted
                 end
        started_at = source["started_at"]
        last_activity_at = source["last_activity_at"]
        {
          started_at: started_at,
          last_activity_at: last_activity_at,
          session_duration_ms: session_duration_ms(started_at, last_activity_at, active: live_metrics.is_a?(Hash)),
          turn_records: Array(source["turn_records"]),
          tool_records: Array(source["tool_records"]),
          active_turn: source["active_turn"],
          active_tools: Array(source["active_tools"])
        }
      end

      def read_analytics(session_id)
        path = File.join(@session_class.session_dir(session_id, state_dir: default_state_dir), "analytics.json")
        return {} unless File.file?(path)

        data = JSON.parse(File.read(path))
        data.is_a?(Hash) ? data : {}
      rescue JSON::ParserError, SystemCallError
        {}
      end

      def merge_timing_records(persisted, live)
        (Array(persisted) + Array(live)).each_with_object({}) do |record, records|
          next unless record.is_a?(Hash)

          id = record["id"] || record[:id]
          records[id] = record if id
        end.values
      end

      def session_duration_ms(started_at, last_activity_at, active:)
        started = Time.iso8601(started_at.to_s)
        finished = active ? Time.now : Time.iso8601(last_activity_at.to_s)
        [((finished - started) * 1000).round, 0].max
      rescue ArgumentError
        nil
      end

      def first_preview_for(session)
        raw = session.first_preview || session.last_prompt || ""
        norm = raw.to_s.gsub(/\s+/, " ").strip
        return "" if norm.empty?

        norm.length > 80 ? "#{norm[0, 80]}…" : norm
      rescue StandardError
        ""
      end

      def read_history(id)
        raw = @manager.read_responses(id, since_time: nil, state_dir: @state_dir)
        raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
      rescue StandardError
        []
      end

      # @param msgs [Array<Hash>] a session's messages; symbol keys from disk,
      #   string keys from a Bridge snapshot
      def messages_for_display(msgs)
        filtered = []
        Array(msgs).each do |m|
          role = (m[:role] || m["role"]).to_s
          content = (m[:content] || m["content"]).to_s
          next if role == "system"
          next if role == "tool_response"

          stripped = Samagotchi::OutputFormatter.strip(content)
          next if stripped.empty?

          norm_role = role == "model" ? "assistant" : role
          # normalize assistant vs model, keep user as is
          norm_role = "assistant" if norm_role == "assistant" || norm_role == "model"
          norm_role = "user" if norm_role == "user"
          next unless %w[user assistant].include?(norm_role)

          message = { role: norm_role, content: stripped }
          message[:html] = @markdown_renderer.render(stripped) if norm_role == "assistant" && @markdown_renderer.available?
          filtered << message
        end
        filtered
      rescue StandardError
        []
      end

      def parse_json(str)
        return nil if str.nil? || str.strip.empty?

        JSON.parse(str)
      rescue JSON::ParserError
        nil
      end

      def parse_since(val)
        return nil if val.nil? || val.to_s.strip.empty?

        # Try ISO8601, then float timestamp
        Time.iso8601(val.to_s)
      rescue ArgumentError
        begin
          Time.at(Float(val.to_s))
        rescue StandardError
          nil
        end
      end

      def default_state_dir
        @state_dir || Session.default_state_dir
      end

      def json_response(status, payload)
        body = JSON.generate(payload)
        [status, { "Content-Type" => "application/json; charset=utf-8", "Content-Length" => body.bytesize.to_s, "Cache-Control" => "no-store", "Access-Control-Allow-Origin" => "*" }, [body]]
      end

      def error_response(status, code, detail)
        json_response(status, { error: code, detail: detail })
      end


      def not_found(path:)
        error_response(404, "not_found", "not found: #{path}")
      end

      # Proxy body that streams from the per-session Bridge TCP server.
      class ProxyStreamBody
        def initialize(host:, port:, session_id:, query:, headers:)
          @client = BridgeClient.new(session_id: session_id, port: port, host: host)
          @query = query
          @headers = headers
        end

        def each(&block)
          # Forward the browser's auto-reconnect cursor: the bridge prefers the
          # Last-Event-ID header over ?from_seq, and the reconnect URL carries a
          # stale initial cursor — without this the bridge would replay content
          # already delivered (duplicate bubbles).
          @client.stream(query: @query, last_event_id: @headers["HTTP_LAST_EVENT_ID"], &block)
        end
      end
    end
  end
end
