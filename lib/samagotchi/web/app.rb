# frozen_string_literal: true

require "cgi/escape" # CGI.escapeHTML; Ruby 4.0 ships only cgi/escape
require "digest"
require "fileutils"
require "json"
require "time"
require "uri"
require "rack"
require "rack/request"

require_relative "../bridge_client"
require_relative "../bridge/bounded_queue"
require_relative "../session"
require_relative "../session_manager"
require_relative "../session_commands"
require_relative "../steer"
require_relative "../host_registry"
require_relative "../model_profile"
require_relative "../project_scope"
require_relative "../version"
require_relative "../config"
require_relative "../output_formatter"
require_relative "../image_store"
require_relative "../context_note"
require_relative "../recap_store"
require_relative "markdown_renderer"
require_relative "message_parts"
require_relative "session_summary"
require_relative "../log"

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
      # An uploaded image may be this big before it is downscaled.
      MAX_IMAGE_UPLOAD_BYTES = 20 * 1024 * 1024
      SESSION_ID_RE = /\A[0-9A-Za-z-]{1,64}\z/
      IMAGE_NAME_RE = /\A[0-9a-f]{16}\.(png|jpe?g|gif|webp)\z/
      IMAGE_TYPES = { "png" => "image/png", "jpg" => "image/jpeg", "jpeg" => "image/jpeg", "gif" => "image/gif",
                      "webp" => "image/webp" }.freeze

      # POST /stop waits this long for the worker to let go of the session.
      STOP_WAIT_SECONDS = 2.0

      # GET /api/events: a `: ping` this often while idle, a queue this deep
      # per tab (an overflow ends the connection; the reconnect's snapshot
      # is the recovery), and the loop's longest wait before it looks at
      # whether the hub or the server is shutting down.
      EVENTS_HEARTBEAT = 15.0
      EVENTS_QUEUE = 256
      # Seconds GET /api/models waits for the hosts' lists before answering
      # with what it has (the listing goes on and fills the registry's cache).
      MODELS_WAIT_TIMEOUT = 4.0
      EVENTS_POLL = 1.0

      # A callable the event loops ask whether the server still runs;
      # Server.start points it at WEBrick's status once it has the server.
      attr_writer :server_running

      # @param bridge_wait_timeout [Float] bounded seconds to wait for a
      #   freshly-spawned worker's bridge before answering POST /api/sessions.
      # @param view ["stage", "turn"] the page's view of a turn (web.view);
      #   ?view=stage|turn overrides it for one page load
      # @param annotate_presets [String, Array] the quick replies next to
      #   Annotate (web.annotate_presets, "|"-separated); "" shows none. The
      #   page parses them (annotate_presets.js).
      # @param hub [SessionHub, nil] the session projection GET /api/events
      #   streams from; without one the route answers 503
      # @param registry [HostRegistry, nil] the hosts GET /api/models lists
      #   (built from the config on first use)
      # @param models_wait_timeout [Float] bounded seconds GET /api/models
      #   waits for the hosts' lists
      # @param lan [Hash, nil] LAN mode (web.host: lan): { ip:, token: },
      #   the address the server also listens on and its access token (a
      #   String, or a Web::Token::Source that follows the file); nil:
      #   loopback only, no token
      def initialize(manager: nil, session_class: nil, state_dir: nil, public_dir: nil,
                     bridge_wait_timeout: BRIDGE_WAIT_TIMEOUT, markdown: false, view: Config::BY_KEY["web.view"].default, hub: nil,
                     annotate_presets: Config::BY_KEY["web.annotate_presets"].default,
                     events_heartbeat: EVENTS_HEARTBEAT, events_queue: EVENTS_QUEUE,
                     registry: nil, models_wait_timeout: MODELS_WAIT_TIMEOUT, lan: nil)
        @manager = manager || SessionManager
        @registry = registry
        @models_wait_timeout = models_wait_timeout
        @models_mutex = Mutex.new
        @models_thread = nil
        @session_class = session_class || Session
        @state_dir = state_dir
        @public_dir = public_dir || File.expand_path("public", __dir__)
        @bridge_wait_timeout = bridge_wait_timeout
        @markdown_renderer = MarkdownRenderer.new(enabled: markdown)
        @view = view
        @annotate_presets = annotate_presets.is_a?(Array) ? annotate_presets.join("|") : annotate_presets.to_s
        @hub = hub
        @events_heartbeat = events_heartbeat
        @events_queue = events_queue
        @server_running = -> { true }
        @lan = lan
        @refused_mutex = Mutex.new
        @refused_logged = {}
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = route(env)
        log_request(env, response, started)
        response
      end

      private

      # The routes, first match wins: a handler takes the request and the
      # path's captures (the session id, an image's name).
      ROUTES = [
        ["GET", %r{\A/(?:index\.html)?\z}, :serve_index],
        ["GET", %r{\A/api/sessions\z}, :handle_list],
        ["POST", %r{\A/api/sessions\z}, :handle_create],
        ["GET", %r{\A/api/info\z}, :handle_info],
        ["GET", %r{\A/api/models\z}, :handle_models],
        ["GET", %r{\A/api/events\z}, :handle_events],
        ["GET", %r{\A/api/sessions/([^/]+)/stream\z}, :handle_stream],
        ["GET", %r{\A/api/sessions/([^/]+)/output\z}, :handle_output],
        ["POST", %r{\A/api/sessions/([^/]+)/cancel\z}, :handle_cancel],
        ["POST", %r{\A/api/sessions/([^/]+)/stop\z}, :handle_stop],
        ["POST", %r{\A/api/sessions/([^/]+)/archive\z}, :handle_archive],
        ["POST", %r{\A/api/sessions/([^/]+)/unarchive\z}, :handle_unarchive],
        ["POST", %r{\A/api/sessions/([^/]+)/turn\z}, :handle_turn],
        ["POST", %r{\A/api/sessions/([^/]+)/answer\z}, :handle_question_answer],
        ["POST", %r{\A/api/sessions/([^/]+)/question/dismiss\z}, :handle_question_dismiss],
        ["POST", %r{\A/api/sessions/([^/]+)/command\z}, :handle_command],
        ["POST", %r{\A/api/sessions/([^/]+)/images\z}, :handle_image_upload],
        ["GET", %r{\A/api/sessions/([^/]+)/images/([^/]+)\z}, :handle_image],
        ["GET", %r{\A/api/sessions/([^/]+)\z}, :handle_show],
        ["DELETE", %r{\A/api/sessions/([^/]+)\z}, :handle_delete]
      ].freeze

      def route(env)
        req = Rack::Request.new(env)
        return forbidden unless local_host_header?(env)
        return cross_origin if cross_site?(env)
        if @lan && !LOOPBACK_PEERS.include?(env["REMOTE_ADDR"].to_s)
          denied = token_gate(req)
          return denied if denied
        end

        ROUTES.each do |verb, pattern, handler|
          next unless req.request_method == verb && (m = pattern.match(req.path_info))
          # Every /api/sessions/:id route: an id that isn't one (Session.valid_id?,
          # "..", a %2F) is an unknown session before any handler makes a path.
          if req.path_info.start_with?("/api/sessions/") && !Session.valid_id?(m.captures.first)
            return error_response(404, "not_found", "Session not found: #{m.captures.first.to_s[0, 80]}")
          end

          return send(handler, req, *m.captures)
        end
        # Anything else is a file under public_dir (/assets/*, /public/* or
        # a bare path such as /style.css), or 404.
        serve_static(req)
      rescue StandardError => e
        Log.exception(:web, "request_failed", e, method: env["REQUEST_METHOD"], path: env["PATH_INFO"])
        error_response(500, "internal_error", e.message)
      end

      # API requests at debug level (not the page and its assets): method,
      # path, status, time. Never a body or the query; only a tail=1 read
      # (the page's end-of-turn re-read) is marked, to tell it from a full one.
      def log_request(env, response, started)
        path = env["PATH_INFO"].to_s
        return unless path.start_with?("/api/") && Log.level?(:debug)

        tail = env["QUERY_STRING"].to_s.split("&").include?("tail=1") ? { tail: true } : {}
        Log.debug(:web, "request", sid: path[%r{\A/api/sessions/([^/]+)}, 1], method: env["REQUEST_METHOD"], path: path,
                                   status: response[0], **tail,
                                   ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end

      LOOPBACK_NAMES = %w[127.0.0.1 [::1] localhost].freeze
      LOOPBACK_PEERS = %w[127.0.0.1 ::1 ::ffff:127.0.0.1].freeze

      # Only 127.0.0.1 / [::1] / localhost (any port), and in LAN mode the
      # LAN address, are answered. The socket is bound to those, but a Host
      # check stops DNS-rebinding pages. It reads the raw Host header:
      # Rack's req.host trusts X-Forwarded-Host, which such a page could
      # set. A request with no Host (HTTP/1.0) is answered only for a
      # loopback peer.
      def local_host_header?(env)
        host = env["HTTP_HOST"].to_s
        return LOOPBACK_PEERS.include?(env["REMOTE_ADDR"].to_s) if host.empty?

        name = host.downcase.sub(/:\d*\z/, "")
        LOOPBACK_NAMES.include?(name) || (!@lan.nil? && name == @lan[:ip])
      end

      TOKEN_COOKIE = "chi_token"
      # 400 days, the longest a browser keeps a cookie (Chrome's cap). No
      # Secure: the LAN page is plain http. Lax, not Strict: a token link
      # opened from another site (a web messenger) makes its 303 chain
      # cross-site, and a Strict cookie wouldn't ride on the redirected GET;
      # the cross-site check already refuses what Strict would add.
      TOKEN_COOKIE_ATTRIBUTES = "HttpOnly; SameSite=Lax; Path=/; Max-Age=34560000"
      REFUSED_LOG_INTERVAL = 60.0

      # LAN mode, a peer that isn't this machine (the peer is the socket's
      # address, REMOTE_ADDR: never X-Forwarded-For or req.ip, which trust
      # headers a phone could send): every route needs the access token, as
      # the chi_token cookie or an Authorization: Bearer header. The page
      # with ?token= trades it for the cookie and a 303 to itself without
      # it, so the token doesn't stay in the phone's history.
      # @return [Array, nil] the response that refuses it, or nil to go on
      def token_gate(req)
        token = current_token
        if req.get? && ["/", "/index.html"].include?(req.path_info) && req.params.key?("token")
          return token_redirect(req, token) if token_match?(req.params["token"], token)
        else
          auth = req.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer +(\S+)\z/, 1]
          return nil if token_match?(auth, token) || token_match?(req.cookies[TOKEN_COOKIE], token)
        end

        unauthorized(req)
      end

      def current_token
        token = @lan[:token]
        token.respond_to?(:current) ? token.current : token
      end

      def token_match?(given, token)
        return false if given.nil? || given.empty? || token.nil? || token.empty?

        Rack::Utils.secure_compare(given, token)
      end

      # The same page (and its other parameters, as they were written), the
      # token traded for the cookie.
      def token_redirect(req, token)
        query = req.query_string.split("&").reject { |pair| pair.split("=", 2).first == "token" }.join("&")
        location = query.empty? ? req.path_info : "#{req.path_info}?#{query}"
        [303, { "Location" => location, "Set-Cookie" => "#{TOKEN_COOKIE}=#{token}; #{TOKEN_COOKIE_ATTRIBUTES}",
                "Cache-Control" => "no-store", "Content-Length" => "0" }, []]
      end

      def unauthorized(req)
        log_refused(req.get_header("REMOTE_ADDR").to_s, req.path_info)
        return error_response(401, "unauthorized", "chi web on the LAN needs its access token") if req.path_info.start_with?("/api/")

        body = UNAUTHORIZED_PAGE
        [401, { "Content-Type" => "text/html; charset=utf-8", "Content-Length" => body.bytesize.to_s, "Cache-Control" => "no-store" },
         [body]]
      end

      # At most once a minute per peer: a phone with an old link retries.
      def log_refused(peer, path)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        due = @refused_mutex.synchronize do
          @refused_logged.delete_if { |_, at| now - at >= REFUSED_LOG_INTERVAL } if @refused_logged.size > 64
          last = @refused_logged[peer]
          (last.nil? || now - last >= REFUSED_LOG_INTERVAL).tap { |fresh| @refused_logged[peer] = now if fresh }
        end
        Log.warn(:web, "unauthorized", peer: peer, path: path) if due
      end

      # What a phone sees without the token. The field is for a home-screen
      # web app: it has its own cookies, and the QR code opens the browser.
      UNAUTHORIZED_PAGE = <<~HTML
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>chi web: access token needed</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 30rem; margin: 3rem auto; padding: 0 1rem; }
          input { font: inherit; width: 100%; box-sizing: border-box; padding: .5rem; margin: .5rem 0; }
          button { font: inherit; padding: .4rem 1rem; }
        </style></head>
        <body>
        <h1>chi web</h1>
        <p>This page needs chi web's access token. Open the LAN link chi web printed in its terminal, or scan its QR code.</p>
        <form method="get" action="/">
          <label for="token">Or paste the token:</label>
          <input id="token" name="token" autocomplete="off" autocapitalize="off" spellcheck="false">
          <button type="submit">Open</button>
        </form>
        </body></html>
      HTML

      # Another website's page in the desktop browser can send "simple"
      # requests here (a text/plain POST needs no preflight) and would start
      # sessions that run commands. Refused: any request but GET/HEAD from
      # another site (Sec-Fetch-Site cross-site/same-site, or an Origin other
      # than exactly this server's: another local port and "null" are
      # foreign), and GETs of /api/* the same way (no blind reads, no SSE
      # subscriptions). The page itself is same-origin; curl, Net::HTTP and
      # chi's own clients send neither header and pass. A link followed from
      # another site still opens the page (a top-level GET).
      def cross_site?(env)
        foreign = %w[cross-site same-site].include?(env["HTTP_SEC_FETCH_SITE"].to_s.downcase)
        origin = env["HTTP_ORIGIN"]
        foreign ||= !origin.nil? && origin.downcase != "http://#{env["HTTP_HOST"].to_s.downcase}"
        return false unless foreign

        !%w[GET HEAD].include?(env["REQUEST_METHOD"]) || env["PATH_INFO"].to_s.start_with?("/api/")
      end

      def cross_origin
        error_response(403, "cross_origin", "requests from other websites are refused")
      end

      def forbidden
        names = @lan ? "127.0.0.1, [::1], localhost and #{@lan[:ip]}" : "127.0.0.1, [::1] and localhost"
        error_response(403, "forbidden", "only the host names #{names} are answered")
      end

      # The page's scope: ?dir=<folder> lists that folder's project (every
      # session when the folder is in no repo). A dir that isn't an existing
      # absolute folder answers 400 before anything else runs.
      def handle_list(req)
        dir, error = scope_dir(req.params["dir"])
        return error if error

        scope = {}
        root = dir && ProjectScope.root_for(dir)
        scope[:project_root] = root if root
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
        return list_from_hub(root, sort: sort, order: order, limit: limit, offset: offset) if @hub

        # Archived ones too, as the hub's: the page filters them at render.
        scope[:include_archived] = true
        sessions = if @state_dir
                     @manager.list_sessions(state_dir: @state_dir, sort: sort, order: order, limit: limit, offset: offset,
                                            **scope)
                   else
                     @manager.list_sessions(sort: sort, order: order, limit: limit, offset: offset, **scope)
                   end
        roots = {}
        payload = sessions.map do |s|
          owner = session_owner(s.id)
          session_to_json(s, status: displayed_status(s, owner: owner), owner: owner, root_cache: roots)
        end
        # Expose total via header for pagination (total unordered count)
        headers = { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store" }
        # Compute total without limit/offset for header
        if limit || offset.positive?
          total = if @state_dir
                    @manager.list_sessions(state_dir: @state_dir, sort: sort, order: order, **scope).size
                  else
                    @manager.list_sessions(sort: sort, order: order, **scope).size
                  end
          headers["X-Total-Count"] = total.to_s
        end
        body = JSON.generate(payload)
        headers["Content-Length"] = body.bytesize.to_s
        [200, headers, [body]]
      end

      # The list from the hub's projection (the page's fallback and the
      # first paint): the same sort, paging and total as from the files.
      def list_from_hub(root, sort:, order:, limit:, offset:)
        all = @hub.snapshot(project_root: root, sort: sort, order: order)
        page = all.drop(offset)
        page = page.first(limit) if limit
        headers = { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store" }
        headers["X-Total-Count"] = all.size.to_s if limit || offset.positive?
        body = JSON.generate(page)
        headers["Content-Length"] = body.bytesize.to_s
        [200, headers, [body]]
      end

      # A scope folder from the page: [dir, nil] (dir nil when none was
      # given), or [nil, a 400 response] when it isn't an existing absolute
      # folder (a bookmarked worktree deleted since, a typo).
      def scope_dir(value)
        return [nil, nil] if value.nil? || value.to_s.strip.empty?

        dir = value.to_s
        unless dir.start_with?("/") && File.directory?(dir)
          return [nil, error_response(400, "invalid_dir", "not a folder: #{dir}")]
        end

        [File.expand_path(dir), nil]
      end

      # What a second `chi web` probes before starting its own server: this
      # is chi web, and it knows ?dir (features).
      def handle_info(_req)
        json_response(200, { app: "chi-web", version: Samagotchi::VERSION, pid: Process.pid, cwd: Dir.pwd,
                             features: ["dir"], lan: @lan && @lan[:ip] })
      end

      # The models a new session can start on, spelled as chi spells them
      # elsewhere: bare for the default host (what default.model holds), and
      # host:model for another host. The default is the configured model, or
      # what spawn_session gives a session today. The hosts' lists come from
      # the registry's cache (60 s; 10 min for a remote host); the route waits
      # a bounded time for a fresh listing and answers with what it has, a
      # host that failed or the wait running out noted in +warning+, never a
      # failure: the default alone is enough for the page.
      def handle_models(_req)
        default = begin
          ModelProfile.required_model_name
        rescue StandardError
          nil
        end
        models = []
        warnings = []
        begin
          registry = host_registry
          results = await_model_lists(registry)
          if results.nil?
            warnings << "the hosts are still listing their models"
          else
            default_host = registry.default_entry&.name
            ordered = results.keys.sort_by { |name| [name == default_host ? 0 : 1, name] }
            ordered.each do |host|
              data = results[host]
              if data[:error]
                warnings << "#{host}: #{data[:error]}"
                next
              end
              Array(data[:models]).each do |info|
                id = info.id.to_s
                next if id.strip.empty? || id.end_with?(":batch")

                models << { name: host == default_host ? id : "#{host}:#{id}", host: host, id: id }
              end
            end
          end
        rescue StandardError => e
          warnings << e.message
        end
        if default && models.none? { |m| m[:name].casecmp?(default) }
          models.unshift({ name: default, host: nil, id: default })
        end
        payload = { default: default, models: models }
        payload[:warning] = warnings.join("; ") unless warnings.empty?
        json_response(200, payload)
      end

      def host_registry
        @models_mutex.synchronize { @registry ||= HostRegistry.new }
      end

      # The hosts' model lists (cached ones as they are), or the last complete
      # listing (nil when there is none) when this one is not done within the
      # wait. One listing runs at a time; a request that finds one running
      # waits on it. A listing that raised raises here.
      def await_model_lists(registry)
        thread = @models_mutex.synchronize do
          unless @models_thread&.alive?
            @models_thread = Thread.new { registry.list_all_models(force: false) }
            @models_thread.report_on_exception = false
          end
          @models_thread
        end
        thread.join(@models_wait_timeout) ? thread.value : registry.cached_results
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
        body = parse_json(request_body(req))
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        prompt = body["prompt"] || body[:prompt]
        # idle: a session with no first turn, for a first message with
        # images (the page uploads them into it, then sends the turn).
        idle = body["idle"] == true
        if prompt.to_s.strip.empty? && !idle
          return error_response(400, "missing_fields", "prompt is required")
        end
        # dir: the folder the chat starts in (the page's scope); without it,
        # the server's own cwd.
        dir, error = scope_dir(body["dir"])
        return error if error

        folder = dir ? { working_directory: dir } : {}
        # model: the model the session starts on (the start page's picker,
        # spelled as GET /api/models lists it); blank means the default.
        model = (body["model"] || body["model_name"]).to_s.strip
        folder[:model_name] = model unless model.empty?
        # preview: an idle session's first message, sent as its first turn
        # next; the list and the notifications name the session by it
        # until that turn is saved.
        preview = idle ? body["preview"].to_s.strip : ""
        folder[:title] = preview unless preview.empty?
        begin
          session = @manager.spawn_session(prompt: idle ? nil : prompt.to_s, state_dir: @state_dir, **folder)
        rescue ModelProfile::MissingModel => e
          # No model configured, or one qualified with an unknown host.
          return error_response(400, "invalid_model", e.message)
        end
        # The worker's Bridge is the single live transport: wait (bounded) for
        # it so the client can attach without client-side polling.
        port = await_bridge_port(session.id)
        # The projection holds it before the page hears back (no tick wait).
        @hub&.touch(session.id)
        json_response(201, session_to_json(session).merge(bridge_port: port))
      end

      def handle_show(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
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
        # ?cards=1: the page's re-read when a card arrives, for its rendered
        # body (the stream carries the card's plain text only).
        if req.params["cards"] == "1"
          return json_response(200, { cards: cards_for_display(turn_snapshot) })
        end
        snapshot = live && live["session_state_snapshot"]
        last_event_seq = snapshot ? snapshot["event_seq"] : bridge_event_seq(id)
        current_turn = turn_snapshot && turn_snapshot["current_turn"]
        owner = session_owner(id)
        # The file's question only with a live owner: one a dead worker
        # saved can't be answered (its turn is gone).
        pending = if turn_snapshot
                    current_turn && current_turn["pending_question"]
                  elsif owner && session.respond_to?(:pending_question)
                    session.pending_question
                  end
        # A /model in the worker changes it before the file catches up.
        session.model_name = snapshot["model_name"] if snapshot && !snapshot["model_name"].to_s.empty?
        session_json = session_to_json(session, status: displayed_status(session, snapshot, owner: owner), owner: owner)
        # What the worker's server said it served for that model (after a turn).
        if snapshot
          session_json = session_json.merge(served_model: snapshot["served_model"], served_model_for: snapshot["served_model_for"])
        end
        raw_messages = turn_snapshot ? turn_snapshot["messages"] : session.messages
        timing = timing_payload(id, live_metrics: snapshot && snapshot["metrics"])
        # ?tail=1: the page's re-read at the end of a turn wants the final
        # answer's rendered markdown, the status and the timing, not the
        # whole history again (nor a render of every earlier answer).
        if req.params["tail"] == "1"
          return json_response(200, {
            tail: true,
            session: session_json,
            messages: last_assistant_for_display(raw_messages),
            markdown_warning: @markdown_renderer.warning,
            timing: timing
          })
        end

        json_response(200, {
          session: session_json,
          history: read_history(id),
          messages: messages_for_display(raw_messages, parts: req.params["parts"] == "1",
                                                       cwd: session.respond_to?(:working_directory) ? session.working_directory : nil),
          failed_turn: failed_turn_for(session, raw_messages),
          current_turn: current_turn,
          queued: turn_snapshot ? Array(turn_snapshot["queued"]) : [],
          recap: turn_snapshot && turn_snapshot["recap"],
          saved_recap: saved_recap_for(id, session, turn_snapshot),
          continue_offer: turn_snapshot && turn_snapshot["continue_offer"],
          guardrail_warning: turn_snapshot && turn_snapshot["guardrail_warning"],
          plugin_warning: turn_snapshot && turn_snapshot["plugin_warning"],
          # Plugins' slow setup still running (chi.init): the page's init row.
          init_tasks: turn_snapshot ? Array(turn_snapshot["init_tasks"]) : [],
          cards: cards_for_display(turn_snapshot),
          # The composer's / autocomplete; the built-ins until a worker
          # names its plugins' too.
          commands: turn_snapshot&.fetch("commands", nil) || SessionCommands.builtin_registry.listing,
          markdown_warning: @markdown_renderer.warning,
          pending_question: pending,
          last_event_seq: last_event_seq,
          # The stream cursor `<seq>-<epoch>`: a later worker resets it
          # instead of taking the seq as its own. Only the snapshot has it.
          last_event_id: turn_snapshot && turn_snapshot["event_id"],
          timing: timing
        })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # The worker's last cards and between-turns notices (Bridge
      # snapshot[:cards]), a card's body as body_html: rendered markdown
      # when the renderer is on, else the escaped text in a <pre>.
      # @return [Array<Hash>] [] without a live worker
      def cards_for_display(turn_snapshot)
        Array(turn_snapshot && turn_snapshot["cards"]).filter_map do |card|
          next unless card.is_a?(Hash)
          next card unless card["type"].to_s == "card"

          card.merge("body_html" => card_body_html(card["body"].to_s))
        end
      end

      def card_body_html(body)
        return "" if body.strip.empty?

        html = @markdown_renderer.render(body) if @markdown_renderer.available?
        html || "<pre>#{CGI.escapeHTML(body)}</pre>"
      end

      def handle_question_answer(req, id)
        session = @session_class.load(id, state_dir: default_state_dir) rescue nil
        return error_response(404, "not_found", "Session not found: #{id}") unless session

        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        qid = body["id"]
        return error_response(400, "missing_fields", "id is required") if qid.to_s.strip.empty?

        request = ->(client) { client.answer(id: qid, selected: body["selected"], freeform: body["freeform"]) }
        relay(id, bridge_client(id), request, what: "the answer was not sent", cant: "answer questions") do |reply|
          case reply.status
          when 200 then json_response(200, { status: "answered", session_id: id, id: qid })
          # Another client answered first (or the question was cancelled).
          when 409 then error_response(409, "question_not_pending", reply_detail(reply, "question not pending"))
          when 400 then error_response(400, "invalid_answer", reply_detail(reply, "answer rejected"))
          end
        end
      end

      # Leave the pending question unanswered (the card's Dismiss). A question
      # only exists while its worker waits on it, so this needs a live bridge.
      def handle_question_dismiss(req, id)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        qid = body["id"].to_s
        return error_response(400, "missing_fields", "id is required") if qid.strip.empty?

        request = ->(client) { client.dismiss_question(id: qid) }
        relay(id, bridge_client(id), request, what: "the question was not dismissed", cant: "dismiss questions") do |reply|
          case reply.status
          when 200 then json_response(200, { status: "dismissed", session_id: id, id: qid })
          when 409 then error_response(409, "question_not_pending", reply_detail(reply, "question not pending"))
          end
        end
      end

      # A session command typed in the composer (/model, /models, !rollback,
      # !cmd, /continue): the worker runs it (woken as for a turn) and every
      # UI gets its :command_ran. Needs the worker's Bridge.
      def handle_command(req, id)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "invalid JSON body") unless body.is_a?(Hash)

        line = body["line"].to_s.strip
        return error_response(400, "missing_fields", "line is required") if line.empty?

        @manager.resume_session(id, state_dir: @state_dir) if @manager.respond_to?(:resume_session)
        # card: a card's action; its command events say so (no echo).
        request = ->(client) { client.post_command(line: line, client_id: body["client_id"], card: body["card"] == true) }
        relay(id, live_bridge_client(id), request, what: "the command was not run", cant: "run commands") do |reply|
          case reply.status
          when 202 then json_response(202, reply.json || { status: "accepted" })
          when 400 then error_response(400, reply.json&.dig("error") || "unknown_command", reply_detail(reply, "not a session command"))
          end
        end
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # Hand a request to the session's live Bridge (+client+, nil without
      # one) and map its reply. The block gets the reply and answers the
      # statuses its route knows (nil for the rest); every relay maps the
      # rest the same way: 408 deadline_passed or a read timeout → 504
      # worker_timeout (+what+ didn't happen), a 404 for a route the worker
      # doesn't have → 501 not_supported (it runs an older chi that +cant+;
      # 501, not 503: it is live, and the page reads 503 as "not running"),
      # and no live bridge, a refused connection or anything else → 503
      # not_live.
      # @param request [#call] sends with the client, answers its Response
      def relay(id, client, request, what:, cant:)
        return not_live(id) unless client

        reply = request.call(client)
        mapped = yield(reply)
        return mapped if mapped

        case reply.status
        when 408 then worker_timeout(what)
        when 404
          return not_live(id) if reply.json&.dig("error") == "unknown_session"

          error_response(501, "not_supported", BridgeClient.stale_worker_message(id, cant: cant))
        else not_live(id)
        end
      rescue Errno::ETIMEDOUT
        worker_timeout(what)
      rescue SystemCallError, IOError, SocketError
        not_live(id)
      end

      def not_live(id)
        error_response(503, "not_live", "no live bridge for session #{id}")
      end

      # The Bridge's detail for a refusal, or +fallback+.
      def reply_detail(reply, fallback)
        reply.json&.dig("detail") || fallback
      end

      # The worker didn't take a request in time: its read timed out, or the
      # Bridge read it after its deadline (408 deadline_passed) and dropped
      # it. Either way +what+ didn't happen, and a frozen worker that wakes
      # won't do it (BridgeClient::DEADLINE_SHARE).
      def worker_timeout(what)
        error_response(504, "worker_timeout", "the session's worker did not answer, so #{what}")
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
        body = parse_json(request_body(req))
        unless body.is_a?(Hash)
          return error_response(400, "invalid_json", "invalid JSON body")
        end
        prompt = body["prompt"] || body[:prompt]
        client_id = body["client_id"] || body[:client_id]
        if prompt.to_s.strip.empty?
          return error_response(400, "missing_fields", "prompt is required")
        end
        images = turn_images(id, body["images"])
        return error_response(400, "bad_images", images) if images.is_a?(String)

        result = SessionManager.deliver_turn(id, prompt: prompt.to_s, client_id: client_id, images: images, state_dir: @state_dir,
                                             manager: @manager, bridge: -> { live_bridge_client(id) })
        case result[:status]
        when :accepted then json_response(202, result[:ack])
        when :refused then json_response(result[:code], result[:ack])
        when :timeout then error_response(504, "worker_timeout", result[:ack]["detail"])
        else error_response(500, "enqueue_failed", "could not write turn input")
        end
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # A turn's images as [{file:, name:}] (refs to uploads already in the
      # session's images/), or a String saying what's wrong. Never a path.
      def turn_images(id, raw)
        return [] if raw.nil?

        session_dir = image_session_dir(id)
        return "unknown session" unless session_dir

        ImageStore.check_refs(session_dir, raw)
      end

      # The session's folder, or nil for an id that isn't one.
      def image_session_dir(id)
        return nil unless SESSION_ID_RE.match?(id.to_s)

        @session_class.load(id, state_dir: default_state_dir)
        Session.session_dir(id, state_dir: default_state_dir)
      rescue ArgumentError
        nil
      end

      # POST /api/sessions/:id/images: the raw image as the body (a paste or
      # a drop), ?name= for its file name. Stored like any other image
      # (converted, downscaled); answers the ref the turn then names.
      def handle_image_upload(req, id)
        session_dir = image_session_dir(id)
        return error_response(404, "not_found", "unknown session") unless session_dir

        length = req.content_length.to_i
        if length > MAX_IMAGE_UPLOAD_BYTES
          return error_response(413, "too_large", "an image may be up to #{MAX_IMAGE_UPLOAD_BYTES / 1024 / 1024} MB")
        end

        bytes = request_body(req, MAX_IMAGE_UPLOAD_BYTES + 1).to_s.b
        if bytes.bytesize > MAX_IMAGE_UPLOAD_BYTES
          return error_response(413, "too_large", "an image may be up to #{MAX_IMAGE_UPLOAD_BYTES / 1024 / 1024} MB")
        end

        name = File.basename(req.params["name"].to_s)[0, 120]
        ref = ImageStore.ingest(session_dir, bytes: bytes, name: name.empty? ? "image" : name, source: "user")
        json_response(201, ref)
      rescue ImageStore::Error => e
        error_response(422, "bad_image", e.message)
      end

      # GET /api/sessions/:id/images/<hash>.<ext>: a stored image (only
      # raster types; never svg), for the page's thumbnails.
      def handle_image(_req, id, name)
        session_dir = image_session_dir(id)
        return not_found(path: "images/#{name}") unless session_dir && IMAGE_NAME_RE.match?(name.to_s)

        path = File.join(session_dir, ImageStore::DIR, name)
        return not_found(path: "images/#{name}") unless File.file?(path) && !File.symlink?(path)

        body = File.binread(path)
        [200, { "Content-Type" => IMAGE_TYPES.fetch(File.extname(name).delete(".")), "Content-Length" => body.bytesize.to_s,
                "X-Content-Type-Options" => "nosniff", "Cache-Control" => "private, max-age=86400" }, [body]]
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

      # The Bridge decides the reason (Bridge::CANCEL_REASONS; anything
      # else is manual) and the reply echoes its choice. No reason: user.
      def handle_cancel(req, id)
        @session_class.load(id, state_dir: default_state_dir)

        body = request_body(req)
        parsed = body.nil? || body.strip.empty? ? nil : parse_json(body)
        reason = (parsed["reason"] if parsed.is_a?(Hash)).to_s.strip
        reason = "user" if reason.empty?

        request = ->(client) { client.cancel(reason: reason) }
        relay(id, bridge_client(id), request, what: "the turn was not cancelled", cant: "cancel turns") do |reply|
          case reply.status
          when 202
            json_response(202, { status: "cancel_requested", session_id: id, reason: reply.json&.dig("reason"), via: "bridge" })
          # No active turn to cancel.
          when 409 then json_response(409, { error: "not_running", detail: "no active turn to cancel", session_id: id })
          end
        end
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def handle_stop(_req, id)
        # Bounded, so a Rack thread isn't held long; a worker still exiting
        # after it just means an immediate resume finds it (rare).
        @manager.stop_session(id, state_dir: @state_dir, wait: STOP_WAIT_SECONDS)
        @hub&.touch(id)
        json_response(200, { status: "stopped", session_id: id })
      rescue SessionManager::OwnedByTUI => e
        error_response(409, "owned_by_tui", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # POST /api/sessions/:id/archive: hide it (and its delegates) from the
      # lists, keep it for good. A live idle worker is stopped first; a turn
      # running in it or a delegate, a chi REPL's session and a scratch one
      # are refused (409).
      def handle_archive(_req, id)
        result = @manager.archive_session(id, state_dir: @state_dir, wait: STOP_WAIT_SECONDS)
        (result[:archived] + result[:discarded]).each { |sid| @hub&.touch(sid) }
        json_response(200, { status: "archived", session_id: result[:id], archived: result[:archived],
                             stopped: result[:stopped], discarded: result[:discarded] })
      rescue SessionManager::OwnedByTUI
        error_response(409, "owned_by_tui", "session #{id} is open in a chi REPL; close it there first")
      rescue SessionManager::ArchiveRefused => e
        error_response(409, e.reason == :scratch ? "scratch" : "busy", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # POST /api/sessions/:id/unarchive: back to the lists, delegates too.
      def handle_unarchive(_req, id)
        result = @manager.unarchive_session(id, state_dir: @state_dir)
        result[:unarchived].each { |sid| @hub&.touch(sid) }
        json_response(200, { status: "unarchived", session_id: result[:id], unarchived: result[:unarchived] })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # DELETE /api/sessions/:id: the session for good. A live worker is
      # stopped first (the page's confirm says so); a chi REPL's session is
      # refused.
      def handle_delete(_req, id)
        result = @manager.delete_session(id, state_dir: @state_dir, stop: true, wait: STOP_WAIT_SECONDS)
        @hub&.touch(result[:id])
        json_response(200, { status: "deleted", session_id: result[:id], stopped: result[:stopped] })
      rescue SessionManager::OwnedByTUI
        error_response(409, "owned_by_tui", "session #{id} is open in a chi REPL; close it there first")
      rescue SessionManager::DeleteRefused => e
        error_response(409, e.reason.to_s, "#{e.message}; try again in a moment")
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
          "X-Accel-Buffering" => "no"
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
        [200, headers, ProxyStreamBody.new(host: DEFAULT_HOST, port: bridge_port, session_id: id, query: query, headers: req.env,
                                           server_running: @server_running)]
      end

      # GET /api/events: the session list as one SSE stream per tab. The
      # first frame is the hub's snapshot (scoped by ?dir= as the list is),
      # then `session` for an upsert and `session_gone` for a removal, with
      # a `: ping` while idle. Frame ids are the hub's seq, for the log's
      # sake: there is no replay, a reconnect starts with a fresh snapshot.
      def handle_events(req)
        return error_response(503, "no_hub", "this chi web has no session hub") unless @hub

        dir, error = scope_dir(req.params["dir"])
        return error if error

        root = dir && ProjectScope.root_for(dir)
        headers = {
          "Content-Type" => "text/event-stream",
          "Cache-Control" => "no-cache",
          "Connection" => "keep-alive",
          "X-Accel-Buffering" => "no"
        }
        body = EventsBody.new(hub: @hub, project_root: root, heartbeat: @events_heartbeat, capacity: @events_queue,
                              server_running: @server_running)
        # As handle_stream: hijack when the handler offers it (rackup's
        # WEBrick buffers enumerable bodies), else an enumerable body.
        if req.env["rack.hijack?"]
          hijack = lambda do |io|
            body.each do |chunk|
              io.write(chunk)
              io.flush
            end
          rescue Errno::EPIPE, Errno::ECONNRESET, IOError
            nil # the tab went away
          end
          return [200, headers.merge("rack.hijack" => hijack), []]
        end

        [200, headers, body]
      end

      # Rack hijack lambda (env["rack.hijack?"] truthy): pipes the bridge's SSE
      # frames directly to the client socket until it disconnects. The handler
      # (WEBrick via rackup) has already sent the status line + headers, so
      # only body bytes go to the socket here.
      def sse_hijack(id, req, port)
        lambda do |io|
          query = req.query_string.to_s.empty? ? "" : "?#{req.query_string}"
          body = ProxyStreamBody.new(host: DEFAULT_HOST, port: port, session_id: id, query: query, headers: req.env,
                                    server_running: @server_running)
          body.each { |chunk| io.write(chunk) }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil # client went away — end the stream quietly
        rescue StandardError => e
          Log.warn(:web, "proxy_failed", sid: id, port: port, error: e.class.name, msg: e.message)
          nil
        end
      end

      # Bounded wait for a freshly-spawned worker's bridge sidecar so the
      # response hands the client a live transport without client-side polling.
      # Returns the bridge port, or nil when it is not up by the deadline (the
      # session still exists; EventSource auto-reconnect covers late binders).
      def await_bridge_port(session_id, timeout: @bridge_wait_timeout)
        return nil if timeout.nil? || timeout <= 0

        BridgeClient.poll(timeout, interval: BridgeClient::SPAWN_POLL_INTERVAL) { bridge_sidecar_port(session_id) }
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

      def serve_index(req)
        path = File.join(@public_dir, "index.html")
        if File.file?(path)
          body = File.read(path).sub("<body>", "<body #{index_data_attributes(req)}>")
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
          # no-cache + a content ETag: the browser revalidates every asset
          # (the ES-module imports too) and gets a cheap 304 while it is
          # unchanged, so a gem upgrade + chi web restart takes effect on the
          # next load instead of after max-age runs out.
          etag = %("#{Digest::SHA256.hexdigest(body)[0, 32]}")
          headers = { "Cache-Control" => "no-cache", "ETag" => etag }
          return [304, headers, []] if etag_match?(req.get_header("HTTP_IF_NONE_MATCH"), etag)

          [200, headers.merge("Content-Type" => mime_type(full), "Content-Length" => body.bytesize.to_s), [body]]
        else
          not_found(path: req.path_info)
        end
      end

      def etag_match?(if_none_match, etag)
        return false if if_none_match.nil?

        if_none_match.split(",").map { |t| t.strip.delete_prefix("W/") }.any? { |t| t == "*" || t == etag }
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

      # status is turn state (idle/running): SessionSummary.displayed_status,
      # unless the manager can't tell who owns a session (then the file's
      # word stands).
      def displayed_status(session, snapshot = nil, owner: session_owner(session.id))
        unless @manager.respond_to?(:session_owner)
          return snapshot["status"] if snapshot.is_a?(Hash) && snapshot["status"]

          return session.status
        end

        SessionSummary.displayed_status(session, snapshot, owner: owner)
      end

      # @param owner [Hash, nil] #session_owner; its kind is shown as `owner`
      def session_to_json(s, status: s.status, owner: nil, root_cache: nil)
        SessionSummary.build(s, status: status, owner: owner, root_cache: root_cache,
                                session_dir: @session_class.session_dir(s.id, state_dir: default_state_dir))
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
          active_tools: Array(source["active_tools"]),
          # The context last seen and the token sums, for the ctx meter
          # before the next turn streams (live over saved).
          context: source["context"],
          tokens: source["tokens"]
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

      # The recap saved with the session and how many user turns came since:
      # a live worker's (it counts against its Engine's messages), else
      # recap.json against the session file. A stopped session gets its
      # recap without a worker being woken.
      # @return [Hash, nil] {text:, turns_since:}
      def saved_recap_for(id, session, turn_snapshot)
        if turn_snapshot
          saved = turn_snapshot["saved_recap"]
          return saved && { text: saved["text"], turns_since: saved["turns_since"].to_i }
        end

        saved = RecapStore.read(@session_class.session_dir(id, state_dir: default_state_dir))
        return nil unless saved

        messages = Array(session.messages)
        since = messages.drop(saved[:covered].to_i).count { |m| Samagotchi::Steer.turn_prompt?(m) }
        { text: saved[:text], turns_since: since }
      rescue StandardError
        nil
      end

      # The step (iteration) that answered the steer or merged input at
      # +index+: one past the model messages between it and the turn's
      # prompt.
      def steer_step(list, index)
        list[0...index].reverse_each.take_while { |m| !Samagotchi::Steer.turn_prompt?(m) }
                       .count { |m| %w[model assistant].include?((m[:role] || m["role"]).to_s) } + 1
      end

      def read_history(id)
        raw = @manager.read_responses(id, since_time: nil, state_dir: @state_dir)
        raw.map { |chunk| OutputFormatter.strip(chunk) }.reject(&:empty?)
      rescue StandardError
        []
      end

      # @param msgs [Array<Hash>] a session's messages; symbol keys from disk,
      #   string keys from a Bridge snapshot
      # @param parts [Boolean] the turn view's reload (?parts=1): each
      #   assistant message also carries what it did (MessageParts: thinking,
      #   tool calls with params and output), and a message with nothing to
      #   show but that (a text-less step) is kept with empty content
      # @param cwd [String, nil] the session's working directory (the parts'
      #   tool titles are relative to it)
      def messages_for_display(msgs, parts: false, cwd: nil)
        filtered = []
        list = Array(msgs)
        list.each_with_index do |m, index|
          role = (m[:role] || m["role"]).to_s
          content = (m[:content] || m["content"]).to_s
          if Samagotchi::ContextNote.note?(m)
            filtered << { role: "note", content: Samagotchi::ContextNote.text_of(m), label: Samagotchi::ContextNote.label_of(m) }
            next
          end
          # A plugin's steer: a row of the step that answered it, which the
          # page finds by `step`.
          if Samagotchi::Steer.steer?(m)
            filtered << { role: "steer", content: content, source: (m[:source] || m["source"]).to_s, step: steer_step(list, index) }
            next
          end
          next if role == "system"
          next if role == "tool_response"

          stripped = Samagotchi::OutputFormatter.strip_markup(content)
          did = parts && %w[model assistant].include?(role) ? message_parts(list, index, cwd) : nil
          next if stripped.empty? && did.nil?

          norm_role = role == "model" ? "assistant" : role
          # normalize assistant vs model, keep user as is
          norm_role = "assistant" if norm_role == "assistant" || norm_role == "model"
          norm_role = "user" if norm_role == "user"
          next unless %w[user assistant].include?(norm_role)

          message = { role: norm_role, content: stripped }
          # Merged into the running turn (Steer::INPUT_KIND): part of it,
          # read by step +step+.
          message.merge!(merged: true, step: steer_step(list, index)) if norm_role == "user" && Samagotchi::Steer.input?(m)
          images = m[:images] || m["images"]
          message[:images] = Array(images).map { |ref| ImageStore.symbolize(ref).slice(:file, :name, :width, :height) } if norm_role == "user" && images.is_a?(Array) && !images.empty?
          if norm_role == "assistant"
            # What an after_turn hook presented (AnswerDisplay): rendered and
            # copied in place of the answer, sanitised the same way; content
            # stays the model's text, which the page finds the bubble by.
            display = m[:display] || m["display"]
            shown = display.is_a?(String) ? Samagotchi::OutputFormatter.strip_markup(display) : ""
            message[:display] = shown unless shown.strip.empty?
            rendered = message[:display] || stripped
            message[:html] = @markdown_renderer.render(rendered) if !rendered.empty? && @markdown_renderer.available?
          end
          message[:parts] = did if did
          filtered << message
        end
        filtered
      rescue StandardError
        []
      end

      # The last turn failed and its prompt went back to the user: the
      # prompt (session.last_prompt) and why, for the page to show after the
      # conversation as it did live. nil otherwise.
      def failed_turn_for(session, msgs)
        summary = Samagotchi::TurnNote.restored_failure(msgs)
        prompt = session.last_prompt.to_s
        return nil if summary.nil? || prompt.strip.empty?

        { prompt: prompt, summary: summary }
      end

      # The parts of the assistant message at +index+, with the tool_response
      # messages right after it.
      def message_parts(list, index, cwd = nil)
        responses = list.drop(index + 1).take_while { |r| (r[:role] || r["role"]).to_s == "tool_response" }
        MessageParts.for_message(list[index], responses, cwd: cwd)
      end

      # The last message messages_for_display shows as an answer, as a list of
      # at most one: walked backwards so only that one is rendered.
      def last_assistant_for_display(msgs)
        Array(msgs).reverse_each do |m|
          shown = messages_for_display([m]).first
          return [shown] if shown && shown[:role] == "assistant"
        end
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

      # The sessions folder as the page shows it: ~ for the home folder.
      def sessions_dir_label
        home_label(File.expand_path(default_state_dir))
      end

      def home_label(dir)
        home = Dir.home
        return "~" if dir == home

        dir.start_with?("#{home}/") ? "~#{dir.delete_prefix(home)}" : dir
      end

      # <body> data for the page: where sessions are stored, where an
      # all-view new chat starts (the server's cwd), and, when ?dir names a
      # folder in a repo, that project's name and root. A bad dir adds
      # nothing here: the list call answers 400 and the page says so.
      def index_data_attributes(req)
        attrs = { "sessions-dir" => sessions_dir_label, "server-dir" => home_label(Dir.pwd) }
        attrs["view"] = view_name(req.params["view"])
        # Always there: an empty one means no presets, not the default.
        attrs["annotate-presets"] = @annotate_presets
        dir, = scope_dir(req.params["dir"])
        root = dir && ProjectScope.root_for(dir)
        if root
          attrs["project-name"] = File.basename(root)
          attrs["project-dir"] = home_label(root)
        elsif dir.nil?
          # The all view's way back: the project view it came from
          # (?from=), else the project chi web runs in.
          back, = scope_dir(req.params["from"])
          back ||= Dir.pwd
          if (back_root = ProjectScope.root_for(back))
            attrs["back-name"] = File.basename(back_root)
            attrs["back-dir"] = back
          end
        end
        attrs.map { |key, value| %(data-#{key}="#{Rack::Utils.escape_html(value)}") }.join(" ")
      end

      VIEWS = Config::BY_KEY["web.view"].enum_values

      # The view for this page load: ?view=stage|turn wins, anything
      # else leaves the config's choice (web.view).
      def view_name(param)
        VIEWS.include?(param) ? param : @view
      end

      def json_response(status, payload)
        body = JSON.generate(payload)
        [status, { "Content-Type" => "application/json; charset=utf-8", "Content-Length" => body.bytesize.to_s, "Cache-Control" => "no-store" }, [body]]
      end

      # The request body, "" when there is none: WEBrick (through rackup)
      # raises LengthRequired on reading a POST that has neither a
      # Content-Length nor a chunked body (plain `curl -X POST`).
      def request_body(req, limit = nil)
        return "" if req.get_header("CONTENT_LENGTH").nil? && req.get_header("HTTP_TRANSFER_ENCODING").nil?

        req.body.read(*limit)
      end

      def error_response(status, code, detail)
        json_response(status, { error: code, detail: detail })
      end


      def not_found(path:)
        error_response(404, "not_found", "not found: #{path}")
      end

      # One tab's GET /api/events: a bounded queue behind a lambda sink,
      # subscribed and snapshotted as one step under the hub's lock, then
      # drained onto the socket. The loop ends when the hub stops or the
      # server leaves :Running (rackup's WEBrick joins every request thread
      # before returning, so a loop that waited on the queue alone would
      # hang Ctrl-C while a tab is open), and when the queue overflowed:
      # the reconnect's snapshot is the recovery.
      class EventsBody
        # Subscribes now: the snapshot is the list as of the request, and
        # what changes between here and the socket queues up behind it.
        def initialize(hub:, project_root:, heartbeat:, capacity:, server_running:)
          @hub = hub
          @project_root = project_root
          @heartbeat = heartbeat
          @server_running = server_running
          @queue = Bridge::BoundedQueue.new(capacity: capacity)
          @handle, @snapshot = @hub.subscribe(->(event) { @queue.push(event) }, snapshot: true, project_root: project_root)
        end

        def each
          yield frame(nil, "snapshot", sessions: @snapshot)
          last_write = monotonic
          loop do
            event = @queue.pop([@heartbeat, EVENTS_POLL].min)
            if event
              break if @queue.overflow_dropped?

              next unless in_scope?(event)

              yield frame(event.seq, event.type, event.data)
              last_write = monotonic
            else
              # What was queued before the stop still goes out.
              break if @hub.stopped? || !@server_running.call

              if monotonic - last_write >= @heartbeat
                yield ": ping\r\n\r\n"
                last_write = monotonic
              end
            end
          end
        ensure
          close
        end

        # Rack calls it when the body is done with, served or not.
        def close
          @handle.unsubscribe
        end

        private

        # A session outside ?dir's project is not this tab's (its removal
        # still goes out: harmless).
        def in_scope?(event)
          return true if @project_root.nil? || event.type != "session"

          event.data[:session][:project_root] == @project_root
        end

        def frame(id, type, data)
          lines = []
          lines << "id: #{id}" if id
          lines << "event: #{type}"
          JSON.generate(data).each_line { |line| lines << "data: #{line.chomp}" }
          lines.join("\r\n") + "\r\n\r\n"
        end

        def monotonic
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end

      # Proxy body that streams from the per-session Bridge TCP server. It
      # ends when the Bridge closes the stream or, as EventsBody, when the
      # server leaves :Running: rackup's WEBrick joins every request thread
      # before returning, and a read blocked on a quiet worker would hang
      # Ctrl-C of chi web. The bytes go through unchanged.
      class ProxyStreamBody
        def initialize(host:, port:, session_id:, query:, headers:, server_running: -> { true })
          @client = BridgeClient.new(session_id: session_id, port: port, host: host)
          @query = query
          @headers = headers
          @server_running = server_running
        end

        def each(&block)
          # Forward the browser's auto-reconnect cursor: the bridge prefers the
          # Last-Event-ID header over ?from_seq, and the reconnect URL carries a
          # stale initial cursor — without this the bridge would replay content
          # already delivered (duplicate bubbles).
          @client.stream(query: @query, last_event_id: @headers["HTTP_LAST_EVENT_ID"], running: @server_running, &block)
        end
      end
    end
  end
end
