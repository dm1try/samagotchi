# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "uri"
require "rack"
require "rack/request"

require_relative "../session"
require_relative "../session_manager"
require_relative "../output_formatter"

module Samagotchi
  module Web
    # Rack application that serves the Web UI and JSON API.
    #
    # This is the single-port control plane for Chi Web. It never constructs
    # an Engine directly — it talks to SessionManager over the same file IPC
    # that Dashboard uses. SSE streaming is emulated by polling output/ files
    # (worker lives in a forked process) with a heartbeat, so no cross-process
    # subscribe is needed for v1.
    class App
      DEFAULT_HOST = "127.0.0.1"
      HEARTBEAT_INTERVAL = 15.0
      STREAM_POLL_INTERVAL = 0.5
      PREVIEW_CHARS = 40

      def initialize(manager: nil, session_class: nil, state_dir: nil, public_dir: nil)
        @manager = manager || SessionManager
        @session_class = session_class || Session
        @state_dir = state_dir
        @public_dir = public_dir || File.expand_path("public", __dir__)
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
          if (m = %r{\A/api/sessions/([^/]+)/stop\z}.match(req.path_info)) && req.post?
            return handle_stop(req, m[1])
          end
          if (m = %r{\A/api/sessions/([^/]+)/turn\z}.match(req.path_info)) && req.post?
            return handle_turn(req, m[1])
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
        payload = sessions.map { |s| session_to_json(s) }
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
          return error_response(400, "invalid_model", e.message) if e.message.match?(/SAMAGOTCHI_MODEL/)
          raise
        end
        json_response(201, session_to_json(session))
      end

      def handle_show(_req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        history = read_history(id)
        json_response(200, {
          session: session_to_json(session),
          history: history
        })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
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
        if prompt.to_s.strip.empty?
          return error_response(400, "missing_fields", "prompt is required")
        end
        # Ensure session exists and resume worker if needed (like Dashboard#attach_to)
        @manager.resume_session(id, state_dir: @state_dir) if @manager.respond_to?(:resume_session)
        ok = @manager.write_turn_input(id, prompt: prompt.to_s, state_dir: @state_dir)
        unless ok
          return error_response(500, "enqueue_failed", "could not write turn input")
        end
        enqueued_id = SecureRandom.uuid
        json_response(202, { status: "accepted", enqueued_id: enqueued_id, session_id: id })
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

        # Use chunked SSE streaming via Rack hijack / streaming body.
        # We implement a streaming enumerator that polls output/ and emits SSE frames.
        since_param = req.params["since"] || req.params["from_seq"]
        # For file-poll mode, since is a timestamp threshold; for bridge proxy we pass through
        headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no",
          "Access-Control-Allow-Origin" => "*"
        }

        # Attempt to proxy to per-session Bridge if it exists (optional, v1.1)
        bridge_port = bridge_sidecar_port(id)
        if bridge_port
          return proxy_bridge_stream(req, id, bridge_port, headers)
        end

        body = StreamBody.new(
          session_id: id,
          manager: @manager,
          state_dir: @state_dir,
          heartbeat_interval: HEARTBEAT_INTERVAL,
          poll_interval: STREAM_POLL_INTERVAL,
          since_param: since_param
        )

        [200, headers, body]
      end

      # Attempt to proxy SSE from a per-session Bridge instance if sidecar exists.
      def proxy_bridge_stream(req, id, port, headers)
        # Stream by opening a TCP connection to the bridge and piping SSE frames
        require "socket"
        # Build forwarding request: GET /session/:id/stream with Last-Event-ID and ?from_seq=
        query = req.query_string.to_s.empty? ? "" : "?#{req.query_string}"
        body = ProxyStreamBody.new(host: DEFAULT_HOST, port: port, session_id: id, query: query, headers: req.env)
        [200, headers, body]
      rescue StandardError
        # Fallback to file polling if proxy fails
        StreamBody.new(
          session_id: id,
          manager: @manager,
          state_dir: @state_dir,
          heartbeat_interval: HEARTBEAT_INTERVAL,
          poll_interval: STREAM_POLL_INTERVAL,
          since_param: req.params["since"] || req.params["from_seq"]
        ).then { |b| [200, headers, b] }
      end

      def bridge_sidecar_port(session_id)
        dir = @session_class.session_dir(session_id, state_dir: default_state_dir)
        sidecar = File.join(dir, "bridge.json")
        return nil unless File.file?(sidecar)

        data = JSON.parse(File.read(sidecar))
        port = data["port"]
        port.is_a?(Integer) ? port : port.to_i
      rescue StandardError
        nil
      end

      def serve_index(_req)
        path = File.join(@public_dir, "index.html")
        if File.file?(path)
          body = File.read(path)
          [200, { "Content-Type" => "text/html; charset=utf-8", "Content-Length" => body.bytesize.to_s, "Cache-Control" => "no-store" }, [body]]
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

      def session_to_json(s)
        preview = s.last_prompt.to_s.gsub(/\s+/, " ").strip
        preview = "—" if preview.empty?
        preview = "#{preview[0, PREVIEW_CHARS]}…" if preview.length > PREVIEW_CHARS
        {
          id: s.id,
          status: s.status,
          mode: s.mode,
          model_name: s.model_name,
          working_directory: s.working_directory,
          created_at: s.created_at,
          updated_at: s.updated_at,
          last_prompt: s.last_prompt,
          preview: preview,
          short_id: s.id.to_s[0, 8],
          test_run: !!s.test_run
        }
      end

      def read_history(id)
        raw = @manager.read_responses(id, since_time: nil, state_dir: @state_dir)
        raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
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

      # Streaming body that polls output files and emits SSE frames.
      class StreamBody
        def initialize(session_id:, manager:, state_dir:, heartbeat_interval:, poll_interval:, since_param:)
          @session_id = session_id
          @manager = manager
          @state_dir = state_dir
          @heartbeat_interval = heartbeat_interval
          @poll_interval = poll_interval
          @since_param = since_param
          @seen = {}
        end

        def each
          since_time = parse_since(@since_param)
          # Initial replay: emit history once
          emit_history(since_time) { |frame| yield frame }

          last_heartbeat = Time.now
          loop do
            # Check if session went terminal (stopped) — emit reset-like event and continue heartbeating
            sleep(@poll_interval)
            new_chunks = poll_new_chunks(since_time)
            new_chunks.each { |chunk| yield sse_frame(chunk) }

            if Time.now - last_heartbeat >= @heartbeat_interval
              yield ": ping\n\n"
              last_heartbeat = Time.now
            end

            # If session file indicates stopped, keep heartbeating but also emit state event
            # The loop runs until client disconnects (Rack will stop calling each).
          end
        rescue StandardError
          nil
        end

        private

        def parse_since(val)
          return nil if val.nil? || val.to_s.strip.empty?

          Time.iso8601(val.to_s)
        rescue ArgumentError
          begin
            Time.at(Float(val.to_s))
          rescue StandardError
            nil
          end
        end

        def emit_history(since_time)
          raw = @manager.read_responses(@session_id, since_time: since_time, state_dir: @state_dir)
          raw.each do |chunk|
            cleaned = Samagotchi::OutputFormatter.strip(chunk)
            next if cleaned.empty?

            seq = chunk.hash.abs # not monotonic, but dedups via @seen
            next if @seen[seq]

            @seen[seq] = true
            yield sse_frame({ type: "history", content: cleaned })
          end
        rescue StandardError
          nil
        end

        def poll_new_chunks(since_time)
          # Use mtime-based polling via read_responses if since_time provided; otherwise track seen
          since = since_time || (Time.now - 86400) # fallback: last day via mtime filter
          # If since_time was nil, we use dedup approach instead of mtime
          if since_time
            raw = @manager.read_responses(@session_id, since_time: Time.now - 1, state_dir: @state_dir)
          else
            raw = @manager.read_responses(@session_id, since_time: nil, state_dir: @state_dir)
          end
          raw.filter_map do |chunk|
            cleaned = Samagotchi::OutputFormatter.strip(chunk)
            next if cleaned.empty?

            h = chunk.hash
            next if @seen[h]

            @seen[h] = true
            { type: "output", content: cleaned }
          end
        rescue StandardError
          []
        end

        def sse_frame(data)
          json = JSON.generate(data)
          id = SecureRandom.uuid # per-frame id for Last-Event-ID resumption (client can store)
          "id: #{id}\ndata: #{json}\n\n"
        end
      end

      # Proxy body that streams from the per-session Bridge TCP server.
      class ProxyStreamBody
        def initialize(host:, port:, session_id:, query:, headers:)
          @host = host
          @port = port
          @session_id = session_id
          @query = query
          @headers = headers
        end

        def each
          require "socket"
          sock = TCPSocket.new(@host, @port)
          sock.write("GET /session/#{@session_id}/stream#{@query} HTTP/1.1\r\nHost: #{@host}:#{@port}\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n")
          # Skip HTTP headers
          while (line = sock.gets)
            break if line.strip.empty?
          end
          loop do
            chunk = sock.readpartial(4096)
            yield chunk
          rescue EOFError, IOError, Errno::ECONNRESET
            break
          end
        ensure
          sock&.close rescue nil
        end
      end
    end
  end
end
