# frozen_string_literal: true

require "cgi/escape" # CGI.escapeHTML; Ruby 4.0 ships only cgi/escape
require "digest"
require "fileutils"
require "json"
require "time"
require "uri"
require "rack"
require "rack/request"

require_relative "../client_id"
require_relative "../delivery"
require_relative "../answer_tail"
require_relative "../bridge_client"
require_relative "../bridge/bounded_queue"
require_relative "../bridge/card_store"
require_relative "../session"
require_relative "../session_manager"
require_relative "../session_metrics"
require_relative "../session_commands"
require_relative "../steer"
require_relative "../host_registry"
require_relative "../llm_context_override"
require_relative "../model_catalog"
require_relative "../model_profile"
require_relative "../sampling_settings"
require_relative "../served_model"
require_relative "../project_scope"
require_relative "../prompt_history"
require_relative "../version"
require_relative "../config"
require_relative "../output_formatter"
require_relative "../image_store"
require_relative "../context_note"
require_relative "../context_sources"
require_relative "../context_providers"
require_relative "../recap_store"
require_relative "markdown_renderer"
require_relative "capabilities"
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
      # @param hub [SessionHub, nil] the session projection GET /api/sessions
      #   lists and GET /api/events streams from (Server always builds one);
      #   without one both routes answer 503
      # @param registry [HostRegistry, nil] the hosts GET /api/models lists
      #   (nil: built from config.yml's hosts:, again when they change)
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
        @registry_given = !registry.nil?
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
        ["GET", %r{\A/api/history\z}, :handle_history],
        ["GET", %r{\A/api/events\z}, :handle_events],
        ["GET", %r{\A/api/sessions/([^/]+)/stream\z}, :handle_stream],
        ["GET", %r{\A/api/sessions/([^/]+)/output\z}, :handle_output],
        ["POST", %r{\A/api/sessions/([^/]+)/cancel\z}, :handle_cancel],
        ["POST", %r{\A/api/sessions/([^/]+)/tasks/([^/]+)/stop\z}, :handle_task_stop],
        ["POST", %r{\A/api/sessions/([^/]+)/stop\z}, :handle_stop],
        ["POST", %r{\A/api/sessions/([^/]+)/restart\z}, :handle_restart],
        ["POST", %r{\A/api/sessions/([^/]+)/archive\z}, :handle_archive],
        ["POST", %r{\A/api/sessions/([^/]+)/unarchive\z}, :handle_unarchive],
        ["POST", %r{\A/api/sessions/([^/]+)/turn\z}, :handle_turn],
        ["POST", %r{\A/api/sessions/([^/]+)/answer\z}, :handle_question_answer],
        ["POST", %r{\A/api/sessions/([^/]+)/question/dismiss\z}, :handle_question_dismiss],
        ["POST", %r{\A/api/sessions/([^/]+)/command\z}, :handle_command],
        ["POST", %r{\A/api/sessions/([^/]+)/images\z}, :handle_image_upload],
        ["GET", %r{\A/api/sessions/([^/]+)/images/([^/]+)\z}, :handle_image],
        ["GET", %r{\A/api/sessions/([^/]+)/context\z}, :handle_context_list],
        ["GET", %r{\A/api/sessions/([^/]+)/context/([^/]+)\z}, :handle_context_show],
        ["POST", %r{\A/api/sessions/([^/]+)/context\z}, :handle_context_add],
        ["DELETE", %r{\A/api/sessions/([^/]+)/context/([^/]+)\z}, :handle_context_delete],
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
      # (the page's end-of-turn re-read) and a timing=1 one (its fallback
      # when the merge came up short) are marked, to tell them from a full one.
      def log_request(env, response, started)
        path = env["PATH_INFO"].to_s
        return unless path.start_with?("/api/") && Log.level?(:debug)

        params = env["QUERY_STRING"].to_s.split("&")
        marks = {}
        marks[:tail] = true if params.include?("tail=1")
        marks[:timing] = true if params.include?("timing=1")
        Log.debug(:web, "request", sid: path[%r{\A/api/sessions/([^/]+)}, 1], method: env["REQUEST_METHOD"], path: path,
                                   status: response[0], **marks,
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
      # absolute folder answers 400 before anything else runs. The list is
      # the hub's projection (archived ones too: the page filters them at
      # render), with Session.list's sort, paging and total.
      def handle_list(req)
        return error_response(503, "no_hub", "this chi web has no session hub") unless @hub

        dir, error = scope_dir(req.params["dir"])
        return error if error

        root = dir && ProjectScope.root_for(dir)
        # Lazy retention sweep (once per 24h)
        begin
          @manager.retention_sweep_if_due(state_dir: @state_dir)
        rescue StandardError
          nil
        end
        limit = sanitize_limit(req.params["limit"])
        offset = sanitize_offset(req.params["offset"])
        all = @hub.snapshot(project_root: root, sort: sanitize_sort(req.params["sort"]), order: sanitize_order(req.params["order"]))
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
      # is chi web, and it knows ?dir (features). installed: the newest chi
      # on this machine (nil until the hub has looked); newest_workers: the
      # workers it starts run that one, not this chi web's version.
      def handle_info(_req)
        json_response(200, { app: "chi-web", version: Samagotchi::VERSION, installed: @hub&.installed, pid: Process.pid,
                             cwd: Dir.pwd, features: %w[dir newest_workers], lan: @lan && @lan[:ip] })
      end

      # The models a new session can start on, spelled as chi spells them
      # elsewhere: bare for the default host (what default.model holds), and
      # host:model for another host. The default is the configured model, or
      # what spawn_session gives a session today. The hosts' lists come from
      # the registry's cache (60 s; 10 min for a remote host); the route waits
      # a bounded time for a fresh listing and answers with what it has, a
      # host that failed or the wait running out noted in +warning+, never a
      # failure: the default alone is enough for the page.
      # GET /api/history: the prompt history the TUI's ↑ walks, which the
      # composer's ↑/↓ share (PromptHistory), oldest first.
      def handle_history(_req)
        json_response(200, { entries: PromptHistory.entries })
      end

      # A line the page sent, once the worker took it, into the shared prompt
      # history; "history": false (an image-only send's placeholder text)
      # keeps it out. A failed write never fails the send. There's no scratch
      # check: a live scratch session is the REPL's (OwnedByTUI, 409 before
      # any delivery), and one whose REPL died is left as an edge case.
      def record_history(body, line)
        return if body["history"] == false

        PromptHistory.append(line.to_s)
      rescue StandardError => e
        Log.warn(:web, "history_write_failed", error: e.class.name, msg: e.message)
      end

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
            listing = ModelCatalog.listing(results, registry: registry)
            warnings.concat(listing.warnings)
            # the web's own spelling, kept as it was: bare on the default host
            listing.rows.each do |row|
              model = { name: row.host == default_host ? row.id : "#{row.host}:#{row.id}", host: row.host, id: row.id }
              model[:configured] = true if row.configured
              model[:unavailable] = true if row.unavailable
              models << model
            end
          end
        rescue StandardError => e
          warnings << e.message
        end
        if default && models.none? { |m| m[:name].casecmp?(default) }
          models.unshift({ name: default, host: nil, id: default })
        end
        add_sampling(models, registry)
        payload = { default: default, models: models }
        payload[:warning] = warnings.join("; ") unless warnings.empty?
        json_response(200, payload)
      end

      # Each model's configured sampling as /model words it ("temperature=0.6
      # (hosts.work)"), on the models that have some: the picker's tooltip;
      # and each model's LLM context (LLMContextStrategy::Explained#summary).
      # A config that can't be read leaves the list as it is.
      def add_sampling(models, registry)
        return if registry.nil? || models.empty?

        settings = ConfigFile.model_settings
        models.each do |model|
          target = registry.resolve(model[:name])
          names = registry.lookup_names(model[:name], target: target)
          summary = SamplingSettings.summary(target, names: names, models: settings)
          model[:sampling] = summary if summary
          add_llm_context(model, target, names, settings)
        end
      rescue StandardError
        nil
      end

      # The LLM context +model+ starts under (the start page's llm ctx chip);
      # one that can't be read leaves this model without, not the others.
      def add_llm_context(model, target, names, settings)
        model[:llm_context] = LLMContextStrategy.explain(target, names: names, models: settings).summary(nil)
      rescue StandardError
        nil
      end

      # The served model a session's last generation reported (analytics.json,
      # SessionMetrics#persist), for a session no worker runs: shown only
      # while the name it answered is still the session's model, as
      # Engine#served_model does, with the host whose served: expects it.
      # {} when none applies.
      def saved_served_model(session, persisted)
        served = persisted["served_model"]
        model = session.model_name.to_s
        return {} unless served.is_a?(String) && !served.empty? && !model.empty?

        registry = host_registry
        asked = registry.bare_name(model)
        return {} unless persisted["served_model_for"] == asked

        { served_model: served, served_model_for: asked, served_expected_by: saved_served_expected_by(registry, model, served) }
      rescue StandardError
        {}
      end

      # See ServedModel.expected_by; nil when the model doesn't resolve (the
      # mismatch still shows).
      def saved_served_expected_by(registry, model, served)
        ServedModel.expected_by(registry.resolve(model), served)
      rescue StandardError
        nil
      end

      # A session's LLM context strategy, apply rule and budget, each with
      # where it came from (LLMContextStrategy::Explained#summary), as its
      # worker would resolve them; nil when they can't be.
      # (LLMContextStrategy.for_session, shared with the ctx % the session
      # lists count.)
      def llm_context_for(session)
        LLMContextStrategy.for_session(session, registry: host_registry)
      end

      # Built again when config.yml's hosts: changed (compared as read: the
      # YAML read is mtime-cached), so the model picker lists a host added
      # while chi web runs. An injected registry (specs) stays.
      def host_registry
        @models_mutex.synchronize do
          next @registry if @registry_given

          hosts = ConfigFile.hosts_config
          if @registry.nil? || hosts != @registry_hosts
            @registry = HostRegistry.new(hosts_config: hosts)
            @registry_hosts = hosts
            @models_thread = nil # a listing of the old hosts
          end
          @registry
        end
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
        return handle_continue(body, prompt, idle) if body.key?("continues")

        # dir: the folder the chat starts in (the page's scope); without it,
        # the server's own cwd.
        dir, error = scope_dir(body["dir"])
        return error if error

        # llm_context: the session's own LLM context values before its first
        # turn (the start page's llm ctx chip; chi --llm-context), read
        # before anything spawns so a bad one spawns nothing.
        llm_context, error = request_llm_context(body["llm_context"])
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
        folder[:llm_context] = llm_context if llm_context
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
        record_history(body, prompt) if !idle && PromptHistory.shell_line?(prompt.to_s.strip)
        json_response(201, session_to_json(session).merge(bridge_port: port))
      end

      # POST /api/sessions with continues: <id, prefix or last:id>: the next
      # link of that session's chain (SessionManager.continue_session), in its
      # folder, on its model and with its llm_context, so dir, model and
      # llm_context are refused beside it. 409 continued (with next_id, the
      # link that continues it already: the page opens that one),
      # open_children (ids), folder_gone, busy, scratch or owned_by_tui.
      def handle_continue(body, prompt, idle)
        given = body["continues"]
        unless given.is_a?(String) && !given.strip.empty?
          return error_response(400, "invalid_continues", "continues is a session id")
        end
        if (fields = %w[dir model model_name llm_context].select { |key| body.key?(key) }).any?
          return error_response(400, "invalid_continues",
                                "continues takes the previous session's folder, model and llm_context; " \
                                "leave out #{fields.join(", ")}")
        end

        preview = idle ? body["preview"].to_s.strip : ""
        session, error = continue_from(given, prompt: idle ? nil : prompt.to_s, title: preview.empty? ? nil : preview)
        return error if error

        port = await_bridge_port(session.id)
        moved = session.moved_children || []
        # The moved delegates' cards fold under the new link now.
        [session.continues, session.id, *moved].each { |sid| @hub&.touch(sid) }
        record_history(body, prompt) if !idle && PromptHistory.shell_line?(prompt.to_s.strip)
        json_response(201, session_to_json(session).merge(bridge_port: port, moved: moved))
      end

      # SessionManager.continue_session, its refusals as responses: [session,
      # nil] or [nil, the response]. Only its own errors: what fails after
      # the new link started is not a refusal of it.
      def continue_from(given, prompt:, title:)
        [@manager.continue_session(given, prompt: prompt, title: title, state_dir: @state_dir), nil]
      rescue SessionManager::ContinueRefused => e
        extra = e.reason == :continued ? { next_id: e.ids.first } : { ids: e.ids }
        [nil, json_response(409, { error: e.reason.to_s, detail: e.message, **extra })]
      rescue SessionManager::ArchiveRefused => e
        [nil, error_response(409, e.reason == :scratch ? "scratch" : "busy", e.message)]
      rescue SessionManager::OwnedByTUI
        [nil, error_response(409, "owned_by_tui", "session #{given} is open in a chi REPL; close it there first")]
      rescue ModelProfile::MissingModel => e
        [nil, error_response(400, "invalid_model", e.message)]
      rescue Session::AmbiguousId => e
        [nil, error_response(400, "ambiguous_id", e.message)]
      rescue ArgumentError => e
        [nil, error_response(404, "not_found", e.message)]
      end

      # The create request's "llm_context" ({strategy:, apply:, budget:},
      # each a word as /llm-context takes it, "default" for unset) as an
      # override: [override, nil] (nil when absent or all default), or
      # [nil, a 400 response] for anything else.
      def request_llm_context(raw)
        return [nil, nil] if raw.nil?

        fields = LLMContextOverride::COMMAND_WORDS.invert
        unless raw.is_a?(Hash) && raw.all? { |key, word| fields.key?(key) && word.is_a?(String) }
          return [nil, error_response(400, "invalid_llm_context",
                                      "llm_context is an object of #{fields.keys.join(", ")} words")]
        end

        override = LLMContextOverride.update(nil, raw.to_h { |key, word| [fields.fetch(key), word] })
        [override.empty? ? nil : override, nil]
      rescue ArgumentError => e
        [nil, error_response(400, "invalid_llm_context", e.message)]
      end

      def handle_show(req, id)
        # The page's light re-reads: never the whole conversation.
        return handle_cards_read(id) if req.params["cards"] == "1"
        return handle_tail_read(req, id) if req.params["tail"] == "1"
        return handle_timing_read(id) if req.params["timing"] == "1"

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
        snapshot = live && live["session_state_snapshot"]
        last_event_seq = snapshot ? snapshot["event_seq"] : bridge_event_seq(id)
        current_turn = turn_snapshot && turn_snapshot["current_turn"]
        owner = session_owner(id)
        # The file's question only while a worker owns the session: one a
        # dead worker saved can't be answered (its turn is gone), nor a chi
        # REPL's (it shares nothing with the web).
        # A question between turns (the step-limit one) is the snapshot's own.
        pending = if turn_snapshot
                    current_turn ? current_turn["pending_question"] : turn_snapshot["pending_question"]
                  elsif owner&.worker?
                    session.pending_question
                  end
        # A /model in the worker changes it before the file catches up.
        session.model_name = snapshot["model_name"] if snapshot && !snapshot["model_name"].to_s.empty?
        session_json = session_to_json(session, status: displayed_status(session, snapshot, owner: owner), owner: owner)
        # What the worker's server said it served for that model (after a turn);
        # without a worker, what the session's analytics.json last saved.
        persisted = snapshot ? nil : read_analytics(id)
        if snapshot
          session_json = session_json.merge(served_model: snapshot["served_model"], served_model_for: snapshot["served_model_for"],
                                            served_expected_by: snapshot["served_expected_by"])
          # The model notes its prompt carries now (a /model there changes them).
          session_json = session_json.merge(prompt_notes: snapshot["prompt_notes"]) if snapshot["prompt_notes"].is_a?(Array)
        else
          session_json = session_json.merge(saved_served_model(session, persisted))
        end
        # The LLM context strategy the next turn runs under (the info bar's
        # chip): the worker's, else worked out here from the session file.
        session_json = session_json.merge(llm_context: (snapshot && snapshot["llm_context"]) || llm_context_for(session))
        raw_messages = turn_snapshot ? turn_snapshot["messages"] : session.messages
        timing = timing_payload(id, live_metrics: snapshot && snapshot["metrics"], persisted: persisted)
        json_response(200, {
          session: session_json,
          history: read_history(id),
          messages: messages_for_display(raw_messages, parts: req.params["parts"] == "1",
                                                       cwd: session.working_directory),
          failed_turn: failed_turn_for(session, raw_messages),
          current_turn: current_turn,
          queued: turn_snapshot ? Array(turn_snapshot["queued"]) : [],
          # Commands waiting for the running turn's end (their bubbles).
          queued_commands: turn_snapshot ? Array(turn_snapshot["queued_commands"]) : [],
          recap: turn_snapshot && turn_snapshot["recap"],
          saved_recap: saved_recap_for(id, session, turn_snapshot),
          continue_offer: turn_snapshot && turn_snapshot["continue_offer"],
          guardrail_warning: turn_snapshot && turn_snapshot["guardrail_warning"],
          plugin_warning: turn_snapshot && turn_snapshot["plugin_warning"],
          # Plugins' slow setup still running (chi.init): the page's init row.
          init_tasks: turn_snapshot ? Array(turn_snapshot["init_tasks"]) : [],
          cards: cards_for_display(turn_snapshot ? turn_snapshot["cards"] : saved_cards(id)),
          # The composer's / autocomplete; the built-ins until a worker
          # names its plugins' too.
          commands: turn_snapshot&.fetch("commands", nil) || SessionCommands.builtin_registry.listing,
          markdown_warning: @markdown_renderer.warning,
          capabilities: Capabilities.for(@markdown_renderer).to_h,
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

      # ?cards=1: the page's re-read when a card arrives, for its rendered
      # body (the stream carries the card's plain text only). The worker's
      # cards from its light GET tail, else the saved ones; the session file
      # is only stat'ed (the 404), never parsed.
      def handle_cards_read(id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        tail = live_tail(id)
        json_response(200, { cards: cards_for_display(tail ? tail["cards"] : saved_cards(id)) })
      end

      # ?tail=1: the page's re-read at the end of a turn wants the final
      # answer's rendered markdown, the status and the timing, not the whole
      # history again (nor a render of every earlier answer). Live: the
      # worker's GET tail alone (no session file read); else the file. The
      # session part is what the page reads of it (id, status, used memory
      # names, the model notes its prompt carried: the first turn's build or
      # a /model records them). ?turn_id=: that turn's answer (a queued
      # turn's page re-reads after the next one started). ?recent=1 (the page since this
      # release): the timing's records are the newest turn's (#recent_timing),
      # which the page merges by id; without it, the whole timing as before.
      def handle_tail_read(req, id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        turn_id = req.params["turn_id"].to_s.strip
        turn_id = nil if turn_id.empty?
        tail = live_tail(id, turn_id: turn_id)
        state = tail && tail["session_state_snapshot"]
        if state.is_a?(Hash)
          session_json = { id: id, status: state["status"], used_memory_names: Array(state["used_memory_names"]),
                           prompt_notes: Array(state["prompt_notes"]) }
          messages = last_assistant_for_display([tail["answer"]].compact)
        else
          session = @session_class.load(id, state_dir: default_state_dir)
          state = nil
          session_json = { id: id, status: displayed_status(session), used_memory_names: Array(session.used_memory_names),
                           prompt_notes: session.prompt_notes.map(&:to_h) }
          messages = last_assistant_for_display(session.messages, turn_id: turn_id)
        end
        live_metrics = state && state["metrics"]
        # Without recent=1: a tab opened before this release (it replaces its
        # timing with the reply's). Remove this branch after the next release.
        timing = req.params["recent"] == "1" ? recent_timing(id, live_metrics) : timing_payload(id, live_metrics: live_metrics)
        json_response(200, {
          tail: true,
          session: session_json,
          messages: messages,
          markdown_warning: @markdown_renderer.warning,
          capabilities: Capabilities.for(@markdown_renderer).to_h,
          timing: timing
        })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # ?timing=1: the whole timing (every record, analytics.json merged with
      # the live ones) and turn_count, when the page's merge comes up short.
      # The worker's GET state, never its messages.
      def handle_timing_read(id)
        return error_response(404, "not_found", "Session not found: #{id}") unless session_exists?(id)

        state = bridge_get_json(id, "state")
        json_response(200, { timing: timing_payload(id, live_metrics: state && state["session_state_snapshot"]&.fetch("metrics", nil)) })
      end

      def session_exists?(id)
        @session_class.exist?(id, state_dir: default_state_dir)
      rescue ArgumentError
        false
      end

      # The worker's light read (Bridge GET tail): {"session_state_snapshot",
      # "answer", "cards", "event_seq", "event_id"}. A worker from before the
      # route answers 404 not_found: its GET snapshot, in the same shape (the
      # answer by AnswerTail). Anything else (no worker, a refused connect, a
      # 500, a timeout) is nil: the caller reads the disk, with no second
      # try at a worker that failed once.
      # @return [Hash, nil]
      def live_tail(id, turn_id: nil)
        status, body = bridge_get(id, turn_id ? "tail?turn_id=#{URI.encode_www_form_component(turn_id)}" : "tail")
        return body if status == 200 && body.is_a?(Hash)
        return nil unless status == 404 && body.is_a?(Hash) && body["error"] == "not_found"

        status, live = bridge_get(id, "snapshot")
        return nil unless status == 200 && live.is_a?(Hash) && live["snapshot"].is_a?(Hash)

        snap = live["snapshot"]
        { "session_state_snapshot" => live["session_state_snapshot"],
          "answer" => AnswerTail.find(snap["messages"], turn_id: turn_id),
          "cards" => snap["cards"], "event_seq" => snap["event_seq"], "event_id" => snap["event_id"] }
      end

      # The worker's last cards and between-turns notices (Bridge
      # cards: CardStore#list), else (no live worker) the ones the last
      # worker saved in the session's folder (#saved_cards), a card's body as
      # body_html: rendered markdown when the renderer is on, else the
      # escaped text in a <pre>.
      # @return [Array<Hash>]
      def cards_for_display(cards)
        Array(cards).filter_map do |card|
          next unless card.is_a?(Hash)
          next card unless card["type"].to_s == "card"

          card.merge("body_html" => card_body_html(card["body"].to_s))
        end
      end

      # As JSON has them (string keys and values), like a snapshot's.
      def saved_cards(id)
        JSON.parse(JSON.generate(Samagotchi::Bridge::CardStore.saved(Session.session_dir(id, state_dir: default_state_dir))))
      rescue StandardError
        []
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

        @manager.resume_session(id, state_dir: @state_dir)
        # card: a card's action; its command events say so (no echo).
        request = ->(client) { client.post_command(line: line, client_id: body["client_id"], card: body["card"] == true) }
        relay(id, live_bridge_client(id), request, what: "the command was not run", cant: "run commands") do |reply|
          case reply.status
          when 202
            record_history(body, line) if PromptHistory.shell_line?(line)
            json_response(202, reply.json || { status: "accepted" })
          when 400
            # One of this chi's own commands the worker doesn't know: it runs an older chi.
            name = reply.json&.dig("error") == "unknown_command" && SessionCommands.builtin_name(line)
            next error_response(501, "not_supported", BridgeClient.stale_worker_message(id, cant: "run #{name}")) if name

            error_response(400, reply.json&.dig("error") || "unknown_command", reply_detail(reply, "not a session command"))
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
      # another unmapped status → 502 bridge_error with the worker's detail
      # (a live worker that failed the request; never 503, which the page
      # reads as "session not running"), and only no live bridge, a refused
      # connection or one that says it isn't this session's → 503 not_live.
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
        else bridge_error(reply, what)
        end
      rescue Errno::ETIMEDOUT
        worker_timeout(what)
      rescue SystemCallError, IOError, SocketError
        not_live(id)
      end

      def not_live(id)
        error_response(503, "not_live", "no live bridge for session #{id}")
      end

      # A live worker refused or failed the request (a 500 in its handler, a
      # status this route doesn't know): 502, with its detail when it sent
      # one. 503 would have the page say the session isn't running, which is
      # untrue and sends the user to restart a healthy worker.
      def bridge_error(reply, what)
        detail = reply_detail(reply, "#{what}: the session's worker answered #{reply.status}")
        error_response(502, "bridge_error", detail)
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

        delivery = body["delivery"] || body[:delivery]
        if (refused = Delivery.refusal(delivery))
          return error_response(400, refused[:error], refused[:detail])
        end

        result = SessionManager.deliver_turn(id, prompt: prompt.to_s, client_id: client_id, images: images,
                                                 delivery: delivery, state_dir: @state_dir, manager: @manager,
                                                 bridge: -> { live_bridge_client(id) })
        case result[:status]
        when :accepted
          record_history(body, prompt)
          json_response(202, result[:ack])
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

      # The process holding the session (an OwnerLock::Owner), or nil. A worker always runs a Bridge; a TUI (plain `chi`) doesn't share.
      def session_owner(id)
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

      # A task id as TaskRuntime.generate_task_id makes it.
      TASK_ID = /\A\d{14}-\h{8}\z/

      # The stop-task button: the worker stops the task as the user
      # (Bridge#handle_task_stop) and its task_wait returns. Its own 404
      # (not this conversation's task) and 409 (already ended) pass through;
      # a 404 from a worker without the route is the stale worker's 501.
      def handle_task_stop(_req, id, task_id)
        return error_response(400, "invalid_task_id", "not a task id: #{task_id.to_s[0, 80]}") unless TASK_ID.match?(task_id)

        @session_class.load(id, state_dir: default_state_dir)
        request = ->(client) { client.stop_task(task_id) }
        relay(id, bridge_client(id), request, what: "the task was not stopped", cant: "stop tasks") do |reply|
          body = reply.json || {}
          case reply.status
          when 200 then json_response(200, { status: body["status"], stop_reason: body["stop_reason"], task_id: task_id, session_id: id })
          when 404 then (error_response(404, "task_not_found", "no task #{task_id} in this conversation") if body["error"] == "task_not_found")
          when 409 then json_response(409, { error: "not_running", status: body["status"], task_id: task_id, session_id: id })
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

      # POST /api/sessions/:id/restart: hand the session to a new worker on
      # the newest chi installed (SessionManager.restart_session). 200
      # {status: "restarted", session_id, from_version, version} (version nil:
      # the new worker is still starting; its bridge_up follows); 409
      # {error: "held" | "not_running" | "unsupported" | "failed", reason, detail} in words; 409
      # owned_by_tui; 404.
      def handle_restart(_req, id)
        result = @manager.restart_session(id, state_dir: @state_dir, client_id: ClientId::WEB_RESTART)
        @hub&.touch(id)
        json_response(200, { status: "restarted", session_id: id, from_version: result.from_version,
                             version: result.version })
      rescue SessionManager::RestartRefused => e
        error = %i[not_running unsupported failed].include?(e.reason) ? e.reason.to_s : "held"
        json_response(409, { error: error, reason: e.reason.to_s, detail: e.message, session_id: id })
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

      # ── Attached context (ContextSources): the session bar's chips ───────
      # A source's command isn't shown (the page may be on a phone over the
      # LAN), and the web adds a URL only, through an installed bundle's
      # provider (ContextProviders): never a command.

      # GET /api/sessions/:id/context: the sources this session sees, muted
      # ones marked, with what the chips show.
      def handle_context_list(_req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        own = ContextSources.session_location(id, state_dir: default_state_dir)
        subs = own.subscriptions
        rows = attached_context(session).map { |attached| context_row(attached, own, subs) }
        json_response(200, { session_id: id, sources: rows, can_add_url: ContextProviders.any? })
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # GET /api/sessions/:id/context/:name: one source with its text.
      def handle_context_show(_req, id, name)
        session = @session_class.load(id, state_dir: default_state_dir)
        attached = find_context(session, name) or return error_response(404, "not_found", "no source #{name[0, 40]}")
        own = ContextSources.session_location(id, state_dir: default_state_dir)
        json_response(200, context_row(attached, own, own.subscriptions).merge(text: attached.snapshot.text))
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      # POST /api/sessions/:id/context {url, why}: the source an installed
      # bundle's provider makes of +url+, attached to this session.
      def handle_context_add(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", "give {url, why}") unless body.is_a?(Hash) && body["url"].is_a?(String)

        url = body["url"].strip
        return error_response(422, "not_a_url", "give an http(s) URL") unless url.match?(%r{\Ahttps?://\S+\z})

        resolved = ContextProviders.resolve(url)
        return error_response(422, "no_provider", "no installed bundle resolves #{url[0, 200]}") unless resolved

        own = ContextSources.session_location(session.id, state_dir: default_state_dir)
        own.add(web_source(resolved, body["why"], own.scope))
        json_response(201, { status: "attached", name: resolved.name })
      rescue ContextProviders::Invalid => e
        error_response(422, "no_provider", e.message)
      rescue ContextSources::Invalid => e
        error_response(409, "exists", e.message)
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def web_source(resolved, why, scope)
        why = ContextSources.one_line(why.is_a?(String) ? why : nil, ContextSources::LINE_MAX_CHARS) || resolved.why
        ContextSources::Source.new(name: resolved.name, cmd: resolved.cmd, every_seconds: resolved.every_seconds, why: why,
                                   hint: resolved.hint, scope: scope, added_by: "web", created_at: Time.now.utc.iso8601,
                                   provider: resolved.bundle)
      end

      # DELETE /api/sessions/:id/context/:name: the session's own source is
      # detached; a project's is muted for this session only.
      def handle_context_delete(_req, id, name)
        session = @session_class.load(id, state_dir: default_state_dir)
        attached = find_context(session, name) or return error_response(404, "not_found", "no source #{name[0, 40]}")
        if attached.location.session?
          attached.location.remove(attached.name)
          json_response(200, { status: "detached", name: attached.name })
        else
          ContextSources.session_location(id, state_dir: default_state_dir).mute(attached.name)
          json_response(200, { status: "muted", name: attached.name })
        end
      rescue ArgumentError => e
        error_response(404, "not_found", e.message)
      end

      def attached_context(session)
        ContextSources.attached(session.id, project_root: session.project_root, state_dir: default_state_dir)
      end

      # @return [ContextSources::Attached, nil]
      def find_context(session, name)
        ContextSources.check_name!(name)
        attached_context(session).find { |attached| attached.name == name }
      rescue ContextSources::Invalid
        nil
      end

      def context_row(attached, own, subs)
        source = attached.source
        snapshot = attached.snapshot
        { name: source.name, scope: source.scope, kind: source.push? ? "push" : "cmd", every_seconds: source.every_seconds,
          why: source.why, hint: snapshot.hint || source.hint, summary: snapshot.summary, error: snapshot.error,
          fetched_at: snapshot.fetched_at, has_text: snapshot.text?, muted: own.muted?(source.name),
          unread: snapshot.text? && subs[source.name]&.read != snapshot.revision }
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
      # first frame is the hub's snapshot (scoped by ?dir= as the list is,
      # with chi's version),
      # then `session` for an upsert, `session_gone` for a removal and `chi`
      # when the newest installed chi changed, with
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

      # GET a read path of the session's live Bridge (+path+: "state",
      # "snapshot", "stats", ...).
      # @return [Hash, nil] parsed JSON body, or nil when no live bridge / timeout.
      def bridge_get_json(session_id, path)
        bridge_client(session_id)&.get_json(path)
      end

      # GET a read path of the session's live Bridge with its status
      # (BridgeClient#get).
      # @return [Array(Integer, Object)] [status, parsed body]; [nil, nil]
      #   with no live bridge or no reply
      def bridge_get(session_id, path)
        client = bridge_client(session_id)
        client ? client.get(path) : [nil, nil]
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
        rel = req.path_info.delete_prefix("/") if rel == req.path_info
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

      # status is turn state (idle/running): SessionSummary.displayed_status.
      def displayed_status(session, snapshot = nil, owner: session_owner(session.id))
        SessionSummary.displayed_status(session, snapshot, owner: owner)
      end

      # @param owner [OwnerLock::Owner, nil] #session_owner; its kind is shown as `owner`
      def session_to_json(s, status: s.status, owner: nil)
        SessionSummary.build(s, status: status, owner: owner,
                                session_dir: @session_class.session_dir(s.id, state_dir: default_state_dir),
                                registry: host_registry)
      end

      # The whole timing: analytics.json's records merged with a live
      # worker's (by id), and turn_count, the finished turns (#turn_count).
      # +persisted+: the session's analytics.json when the caller read it.
      def timing_payload(session_id, live_metrics: nil, persisted: nil)
        persisted ||= read_analytics(session_id)
        live = live_metrics.is_a?(Hash)
        source = if live
                   persisted.merge(live_metrics).merge(
                     "started_at" => persisted["started_at"] || live_metrics["started_at"],
                     "turn_records" => merge_timing_records(persisted["turn_records"], live_metrics["turn_records"]),
                     "tool_records" => merge_timing_records(persisted["tool_records"], live_metrics["tool_records"])
                   )
                 else
                   persisted
                 end
        turns = Array(source["turn_records"])
        timing_from(source, turns, Array(source["tool_records"]), live: live,
                                                                 turn_count: (live && turn_count(live_metrics)) || turns.size)
      end

      # The timing a ?tail=1&recent=1 read sends: a live worker's recent
      # records as its metrics hold them (the newest finished turn's and
      # the unsaved ones, the running turn's finished calls), no
      # analytics.json read; with no worker the disk's, trimmed to the
      # newest turn. turn_count tells the page whether its merge missed one
      # (it then reads ?timing=1).
      def recent_timing(session_id, live_metrics)
        if live_metrics.is_a?(Hash)
          count = turn_count(live_metrics)
          # A metrics hash without the count: the whole timing.
          return timing_payload(session_id, live_metrics: live_metrics) unless count

          turns = Array(live_metrics["turn_records"])
          tools = Array(live_metrics["tool_records"])
          # An older worker's metrics hold every record (before they held the
          # recent ones only, never more than LIVE_RECORDS_CAP turns).
          turns, tools = newest_turn_records(turns, tools, live_metrics["active_turn"]) if turns.size > SessionMetrics::LIVE_RECORDS_CAP
          return timing_from(live_metrics, turns, tools, live: true, turn_count: count)
        end

        persisted = read_analytics(session_id)
        all = Array(persisted["turn_records"])
        turns, tools = newest_turn_records(all, Array(persisted["tool_records"]), nil)
        timing_from(persisted, turns, tools, live: false, turn_count: all.size)
      end

      # The finished turns a live worker counts: its metrics' turns (the
      # loaded history, its own and the running one) less the running one.
      # @return [Integer, nil]
      def turn_count(metrics)
        turns = metrics["turns"]
        return nil unless turns.is_a?(Integer)

        [turns - (metrics["active_turn"] ? 1 : 0), 0].max
      end

      # The newest turn record and its tool records (and the running turn's
      # finished calls).
      def newest_turn_records(turns, tools, active_turn)
        kept = turns.last(1)
        ids = kept.filter_map { |r| r["id"] if r.is_a?(Hash) }
        ids << active_turn["id"] if active_turn.is_a?(Hash) && active_turn["id"]
        [kept, tools.select { |r| r.is_a?(Hash) && ids.include?(r["turn_id"]) }]
      end

      def timing_from(source, turn_records, tool_records, live:, turn_count:)
        started_at = source["started_at"]
        last_activity_at = source["last_activity_at"]
        {
          started_at: started_at,
          last_activity_at: last_activity_at,
          session_duration_ms: session_duration_ms(started_at, last_activity_at, active: live),
          turn_records: turn_records,
          tool_records: tool_records,
          turn_count: turn_count,
          active_turn: source["active_turn"],
          active_tools: Array(source["active_tools"]),
          # The context last seen and the token sums, for the ctx meter
          # before the next turn streams (live over saved).
          context: source["context"],
          tokens: source["tokens"],
          # The memory indexes the session's prompt holds (the ctx tooltip).
          memory_index: source["memory_index"]
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
        # The outputs' ✂ marks (LLM context edits), by id, for the parts.
        marks = parts ? MessageParts.edit_marks(list) : {}
        list.each_with_index do |m, index|
          role = (m[:role] || m["role"]).to_s
          content = (m[:content] || m["content"]).to_s
          if Samagotchi::ContextNote.note?(m)
            note = { role: "note", content: Samagotchi::ContextNote.text_of(m), label: Samagotchi::ContextNote.label_of(m) }
            # A context wake turn's note starts that turn (Steer.turn_prompt?):
            # the page opens the turn with it and pairs it with its record.
            if Samagotchi::Steer.turn_prompt?(m)
              note[:turn_start] = true
              note[:turn_id] = (m[:turn_id] || m["turn_id"]).to_s
            end
            filtered << note
            next
          end
          # A plugin's steer: a row of the step that answered it, which the
          # page finds by `step`.
          if Samagotchi::Steer.steer?(m)
            filtered << { role: "steer", content: content, source: (m[:source] || m["source"]).to_s, step: steer_step(list, index) }
            next
          end
          # A turn that ended with no answer (TurnNote.empty's marker): its
          # empty steps (with ?parts=1) and the item the page draws its
          # notice from; the note itself stays hidden.
          if (marker = Samagotchi::TurnNote.empty_answer(m))
            filtered.concat(empty_answer_items(marker, parts: parts, cwd: cwd))
            next
          end
          next if role == "system"
          next if role == "tool_response"

          stripped = Samagotchi::OutputFormatter.strip_markup(content)
          did = parts && %w[model assistant].include?(role) ? message_parts(list, index, cwd, marks) : nil
          next if stripped.empty? && did.nil?

          norm_role = role == "model" ? "assistant" : role
          # normalize assistant vs model, keep user as is
          norm_role = "assistant" if %w[assistant model].include?(norm_role)
          norm_role = "user" if norm_role == "user"
          next unless %w[user assistant].include?(norm_role)

          message = { role: norm_role, content: stripped }
          # Merged into the running turn (Steer::INPUT_KIND): part of it,
          # read by step +step+; a wake turn's report starts its turn
          # (Steer.turn_prompt?). Its sender (a delegate report, chi send):
          # the page's label.
          if norm_role == "user" && Samagotchi::Steer.input?(m)
            message.merge!(merged: true, step: steer_step(list, index)) unless Samagotchi::Steer.turn_prompt?(m)
            source = (m[:source] || m["source"]).to_s
            message[:source] = source unless source.empty?
          end
          # The turn it started (Engine): the page pairs it with that turn's
          # record by this, not by its place.
          turn_id = m[:turn_id] || m["turn_id"]
          message[:turn_id] = turn_id.to_s if norm_role == "user" && turn_id
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

      # A no-answer turn's marker as display items: each empty step that
      # has something to show (its thinking) as a text-less assistant step
      # (only with +parts+, as other text-less steps), then
      # { role: "empty_answer", retries: }.
      def empty_answer_items(marker, parts:, cwd:)
        steps = parts ? Array(marker[:steps] || marker["steps"]) : []
        items = steps.filter_map do |step|
          did = step.is_a?(Hash) ? MessageParts.for_message(step, [], cwd: cwd) : nil
          { role: "assistant", content: "", parts: did } if did
        end
        items << { role: "empty_answer", content: "", retries: (marker[:retries] || marker["retries"]).to_i }
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
      # messages right after it; +marks+: the session's ✂ marks
      # (MessageParts.edit_marks).
      def message_parts(list, index, cwd = nil, marks = {})
        responses = list.drop(index + 1).take_while { |r| (r[:role] || r["role"]).to_s == "tool_response" }
        MessageParts.for_message(list[index], responses, cwd: cwd, marks: marks)
      end

      # The last message messages_for_display shows as an answer
      # (AnswerTail), as a list of at most one: only that one is rendered.
      def last_assistant_for_display(msgs, turn_id: nil)
        messages_for_display([AnswerTail.find(msgs, turn_id: turn_id)].compact)
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
        # version: the chi that served the page; the events snapshot names
        # the one serving now (an upgraded chi web after a reconnect).
        attrs = { "sessions-dir" => sessions_dir_label, "server-dir" => home_label(Dir.pwd), "version" => Samagotchi::VERSION }
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
          # Read after subscribing: a change in between is also a queued event.
          @installed = @hub.installed
        end

        def each
          # version: the page compares it with the one it was served by;
          # installed: the newest chi on this machine (a later change is a
          # `chi` event).
          yield frame(nil, "snapshot", sessions: @snapshot, version: Samagotchi::VERSION, installed: @installed)
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

        def each(&)
          # Forward the browser's auto-reconnect cursor: the bridge prefers the
          # Last-Event-ID header over ?from_seq, and the reconnect URL carries a
          # stale initial cursor — without this the bridge would replay content
          # already delivered (duplicate bubbles).
          @client.stream(query: @query, last_event_id: @headers["HTTP_LAST_EVENT_ID"], running: @server_running, &)
        end
      end
    end
  end
end
