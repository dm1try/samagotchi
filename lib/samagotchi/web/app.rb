# frozen_string_literal: true

require "cgi/escape" # CGI.escapeHTML; Ruby 4.0 ships only cgi/escape
require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "rubygems/version"
require "time"
require "uri"
require "rack"
require "rack/request"

require_relative "../analytics_file"
require_relative "../client_id"
require_relative "../delivery"
require_relative "../answer_tail"
require_relative "../answer_refs"
require_relative "../question_asked"
require_relative "../bridge_client"
require_relative "../worker_link"
require_relative "../bridge/bounded_queue"
require_relative "../bridge/card_store"
require_relative "../session"
require_relative "../session_manager"
require_relative "../session_metrics"
require_relative "../session_commands"
require_relative "../steer"
require_relative "../host_registry"
require_relative "../llm_context_override"
require_relative "../working_set"
require_relative "../model_catalog"
require_relative "../model_profile"
require_relative "../session_setting"
require_relative "../thinking"
require_relative "../sampling_settings"
require_relative "../served_model"
require_relative "../project_scope"
require_relative "../prompt_history"
require_relative "../version"
require_relative "../config"
require_relative "../output_formatter"
require_relative "../image_store"
require_relative "../message_time"
require_relative "../context_note"
require_relative "../context_sources"
require_relative "../context_providers"
require_relative "../recap_store"
require_relative "../toolkit"
require_relative "../toolkit_suggest"
require_relative "../system_one/client"
require_relative "../turn_flow"
require_relative "../session_chain"
require_relative "../session_access"
require_relative "../review_start"
require_relative "../parent_answers_command"
require_relative "../guardrails/parent_policy"
require_relative "markdown_renderer"
require_relative "token"
require_relative "capabilities"
require_relative "editor"
require_relative "../message_parts"
require_relative "../launch_mode"
require_relative "session_summary"
require_relative "project_list"
require_relative "session_access_routes"
require_relative "principal"
require_relative "participant_access"
require_relative "participants_admin"
require_relative "participant_review"
require_relative "message_display"
require_relative "session_show"
require_relative "session_create"
require_relative "session_control"
require_relative "verify_fresh_routes"
require_relative "push_routes"
require_relative "update_check"
require_relative "proxy_gate"
require_relative "../log"
require_relative "../paths"
require_relative "../redacted_inspect"
require_relative "../chi_home"
require_relative "../child_env"
require_relative "../installed_gem"
require_relative "../live_versions"

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
      # @lan holds the LAN access token.
      include RedactedInspect
      include SessionAccessRoutes
      include ParticipantAccess
      include ParticipantsAdmin
      include ParticipantReview
      include MessageDisplay
      include SessionShow
      include SessionCreate
      include SessionControl
      include VerifyFreshRoutes
      include PushRoutes
      include ProxyGate

      DEFAULT_HOST = BridgeClient::HOST
      BRIDGE_WAIT_TIMEOUT = 10.0
      SESSION_ID_RE = /\A[0-9A-Za-z-]{1,64}\z/

      # GET /api/events: a `: ping` this often while idle, a queue this deep
      # per tab (an overflow ends the connection; the reconnect's snapshot
      # is the recovery), and the loop's longest wait before it looks at
      # whether the hub or the server is shutting down.
      EVENTS_HEARTBEAT = 15.0
      EVENTS_QUEUE = 256
      # Seconds GET /api/models waits for the hosts' lists before answering
      # with what it has (the listing goes on and fills the registry's cache).
      MODELS_WAIT_TIMEOUT = 4.0
      # The one refusal for an update operation (an install, a workers
      # restart, a chi web restart) asked while another one runs: 409 update_running.
      UPDATE_RUNNING = "a chi update operation is already running; try again when it ends"
      EVENTS_POLL = 1.0

      # A callable the event loops ask whether the server still runs;
      # Server.start points it at WEBrick's status once it has the server.
      attr_writer :server_running
      attr_writer :restart_web

      # @param bridge_wait_timeout [Float] bounded seconds to wait for a
      #   freshly-spawned worker's bridge before answering POST /api/sessions.
      # @param view ["stage", "turn"] the page's view of a turn (web.view);
      #   ?view=stage|turn overrides it for one page load
      # @param working_set [Boolean] the stage view's working set
      #   (web.working_set); ?working_set=1|0 overrides it for one page load
      # @param annotate_presets [String, Array] the quick replies next to
      #   Annotate (web.annotate_presets, "|"-separated); "" shows none. The
      #   page parses them (annotate_presets.js).
      # @param editor [String] what a ref opens on this machine (web.editor:
      #   a preset or a URL template, Web::Editor); only a local viewer gets
      #   it (#viewer_editor)
      # @param hub [SessionHub, nil] the session projection GET /api/sessions
      #   lists and GET /api/events streams from (Server always builds one);
      #   without one both routes answer 503
      # @param registry [HostRegistry, nil] the hosts GET /api/models lists
      #   (nil: built from config.yml's hosts:, again when they change)
      # @param models_wait_timeout [Float] bounded seconds GET /api/models
      #   waits for the hosts' lists
      # @param wait_poll_interval [Float] how often POST
      #   /api/sessions/:id/wait looks at the session (ReplyWait's poll)
      # @param lan [Hash, nil] LAN mode (web.host: lan): { ip:, token: },
      #   the address the server also listens on and its access token (a
      #   String, or a Web::Token::Source that follows the file); nil:
      #   loopback only, no token
      # @param grants [Grants, nil] the participants' grants (default: the
      #   store next to +state_dir+, Grants.path)
      # @param public_url [PublicUrl, nil] behind an auth proxy
      #   (web.public_url, ProxyGate): every request needs a token
      # @param public_token [String, Token::Source, nil] the access token
      #   with +public_url+ (the LAN one when both are set)
      # @param push [Push::Runtime, nil] Web Push for this run (PushRoutes);
      #   nil: off (no https public_url, or web.push.enabled false)
      # @param start_dir [String] the folder chi web starts in (StartDir):
      #   where a new session without a dir starts (nil: the cwd)
      def initialize(manager: nil, session_class: nil, state_dir: nil, public_dir: nil,
                     bridge_wait_timeout: BRIDGE_WAIT_TIMEOUT, markdown: false, view: Config::BY_KEY["web.view"].default, hub: nil,
                     annotate_presets: Config::BY_KEY["web.annotate_presets"].default,
                     editor: Config::BY_KEY["web.editor"].default,
                     events_heartbeat: EVENTS_HEARTBEAT, events_queue: EVENTS_QUEUE,
                     registry: nil, models_wait_timeout: MODELS_WAIT_TIMEOUT, lan: nil,
                     working_set: Config::BY_KEY["web.working_set"].default, wait_poll_interval: ReplyWait::POLL_INTERVAL,
                     grants: nil, public_url: nil, public_token: nil, push: nil, start_dir: nil, update_runner: nil,
                     update_blocked: nil)
        @start_dir = start_dir
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
        @working_set = working_set
        @annotate_presets = annotate_presets.is_a?(Array) ? annotate_presets.join("|") : annotate_presets.to_s
        @editor_url = Editor.template(editor)
        @hub = hub
        @events_heartbeat = events_heartbeat
        @events_queue = events_queue
        @server_running = -> { true }
        @lan = lan
        @refused_mutex = Mutex.new
        @refused_logged = {}
        @wait_poll_interval = wait_poll_interval
        @push = push
        @update_mutex = Mutex.new
        @update_running = false
        @update_runner = update_runner || method(:run_update_command)
        @update_blocked = update_blocked || -> { UpdateCheck.blocked_reason }
        init_participant_access(grants, state_dir)
        init_proxy_gate(public_url, public_token)
      end

      def call(env)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = unframed(route(env))
        log_request(env, response, started)
        response
      end

      private

      # No page of chi web's may be framed by another (clickjacking): every
      # HTML answer says so. The page's full CSP is a later change.
      FRAME_HEADERS = { "X-Frame-Options" => "DENY", "Content-Security-Policy" => "frame-ancestors 'none'" }.freeze
      FRAME_DESTS = %w[iframe frame embed object].freeze

      def unframed(response)
        status, headers, body = response
        return response unless headers["Content-Type"].to_s.start_with?("text/html")

        [status, headers.merge(FRAME_HEADERS), body]
      end

      # A frame/embed/object load from anything but the page's own origin.
      def framed?(env)
        FRAME_DESTS.include?(env["HTTP_SEC_FETCH_DEST"].to_s.downcase) &&
          env["HTTP_SEC_FETCH_SITE"].to_s.downcase != "same-origin"
      end

      # The routes, first match wins: a handler takes the request and the
      # path's captures (the session id, an image's name). The fourth column
      # is who may use the route (ROUTE_PERMISSIONS, checked against the
      # request's Principal): :owner, or :participant for one a participant
      # may use too, its handler answering them as theirs (the participant
      # page, the trimmed info, the filtered show; docs/internals/
      # participants.md). A :session route runs in #session_route: an
      # ArgumentError is its unknown session.
      ROUTE_PERMISSIONS = %i[owner participant].freeze
      ROUTES = [
        ["GET", %r{\A/(?:index\.html)?\z}, :serve_index, :participant],
        ["GET", %r{\A/api/sessions\z}, :handle_list, :owner],
        ["GET", %r{\A/api/projects\z}, :handle_projects, :owner],
        ["POST", %r{\A/api/sessions\z}, :handle_create, :owner],
        ["GET", %r{\A/api/sessions/resolve\z}, :handle_resolve, :participant],
        ["GET", %r{\A/api/sessions/summaries\z}, :handle_summaries, :owner],
        ["GET", %r{\A/api/info\z}, :handle_info, :participant],
        ["POST", %r{\A/api/token\z}, :handle_token, :participant],
        ["GET", %r{\A/api/models\z}, :handle_models, :owner],
        ["GET", %r{\A/api/history\z}, :handle_history, :owner],
        ["GET", %r{\A/api/events\z}, :handle_events, :owner],
        ["POST", %r{\A/api/update\z}, :handle_update, :owner],
        ["POST", %r{\A/api/update/restart_workers\z}, :handle_restart_workers, :owner],
        ["POST", %r{\A/api/update/restart_web\z}, :handle_restart_web, :owner],
        ["POST", %r{\A/api/render\z}, :handle_render, :owner],
        ["GET", %r{\A/api/sessions/([^/]+)/stream\z}, :handle_stream, :participant],
        ["GET", %r{\A/api/sessions/([^/]+)/review\z}, :handle_review, :participant, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/output\z}, :handle_output, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/cancel\z}, :handle_cancel, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/tasks/([^/]+)/stop\z}, :handle_task_stop, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/turn/([^/]+)/dequeue\z}, :handle_dequeue_turn, :participant, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/stop\z}, :handle_stop, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/holds\z}, :handle_session_holds, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/holds/stop\z}, :handle_stop_holds, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/restart\z}, :handle_restart, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/archive\z}, :handle_archive, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/unarchive\z}, :handle_unarchive, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/turn\z}, :handle_turn, :participant, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/wait/prepare\z}, :handle_wait_prepare, :participant, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/wait\z}, :handle_wait, :participant, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/verdicts/([^/]+)/fresh\z}, :handle_verify_fresh, :participant, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/notes\z}, :handle_notes, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/wake\z}, :handle_wake, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/worker\z}, :handle_worker, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/exit\z}, :handle_exit, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/recap\z}, :handle_recap, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/guardrails/wrong\z}, :handle_system_one_wrong, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/stats\z}, :handle_stats, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/children/counts\z}, :handle_children_counts, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/turns/([^/]+)/records\z}, :handle_turn_records, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/answer\z}, :handle_question_answer, :owner],
        ["POST", %r{\A/api/sessions/([^/]+)/question/dismiss\z}, :handle_question_dismiss, :owner],
        ["POST", %r{\A/api/sessions/([^/]+)/command\z}, :handle_command, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/images\z}, :handle_image_upload, :owner],
        ["GET", %r{\A/api/sessions/([^/]+)/images/([^/]+)\z}, :handle_image, :owner],
        ["GET", %r{\A/api/sessions/([^/]+)/context\z}, :handle_context_list, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/context/([^/]+)\z}, :handle_context_show, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/context\z}, :handle_context_add, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/context/([^/]+)/push\z}, :handle_context_push, :owner, :session],
        ["DELETE", %r{\A/api/sessions/([^/]+)/context/([^/]+)\z}, :handle_context_delete, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/working_set\z}, :handle_working_set, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/participants\z}, :handle_participants_list, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/participants\z}, :handle_participants_invite, :owner, :session],
        ["DELETE", %r{\A/api/sessions/([^/]+)/participants\z}, :handle_participants_revoke, :owner, :session],
        ["POST", %r{\A/api/sessions/([^/]+)/participants/([^/]+)/cap\z}, :handle_participants_cap, :owner, :session],
        ["GET", %r{\A/api/sessions/([^/]+)/apply\z}, :handle_apply, :owner, :session],
        ["GET", %r{\A/api/participants\z}, :handle_participants_list, :owner],
        ["DELETE", %r{\A/api/participants\z}, :handle_participants_revoke, :owner],
        ["GET", %r{\A/api/push\z}, :handle_push_info, :owner],
        ["POST", %r{\A/api/push/subscriptions\z}, :handle_push_subscribe, :owner],
        ["DELETE", %r{\A/api/push/subscriptions\z}, :handle_push_unsubscribe, :owner],
        # The id checked in the handler (participant_gate_spec fills ([^/]+) captures only).
        ["PATCH", %r{\A/api/push/subscriptions/([^/]+)\z}, :handle_push_prefs, :owner],
        ["DELETE", %r{\A/api/push/subscriptions/([^/]+)\z}, :handle_push_remove, :owner],
        ["POST", %r{\A/api/push/test\z}, :handle_push_test, :owner],
        ["POST", %r{\A/api/push/presence\z}, :handle_push_presence, :owner],
        ["GET", %r{\A/api/sessions/([^/]+)\z}, :handle_show, :participant, :session],
        ["DELETE", %r{\A/api/sessions/([^/]+)\z}, :handle_delete, :owner, :session]
      ].freeze

      def route(env)
        req = Rack::Request.new(env)
        return forbidden unless local_host_header?(env)
        return cross_origin if cross_site?(env)
        return error_response(403, "framed", "chi web's pages can't be framed by another page") if framed?(env)
        # The fragment trade's script, which the 401 page loads: no secret in it.
        return serve_static(req) if req.get? && GATE_FREE_PATHS.include?(req.path_info)
        return probe_info if probe_info?(req)

        principal, denied = token_gate(req)
        return denied if denied

        # The principal the handlers read (#principal): never the body's.
        env[PRINCIPAL_ENV] = principal
        participant_seen(req, principal) unless principal.owner?
        ROUTES.each do |verb, pattern, handler, permission, kind|
          next unless req.request_method == verb && (m = pattern.match(req.path_info))
          # Before the permission: a participant learns nothing of another session.
          return unknown_session(m.captures.first) if other_session?(principal, req.path_info, m.captures)
          return not_permitted_for(req, principal) unless principal.permits?(permission)

          # Every /api/sessions/:id route: an id that isn't one (Session.valid_id?,
          # "..", a %2F) is an unknown session before any handler makes a path.
          # (/api/sessions/resolve and /summaries take no id.)
          if req.path_info.start_with?("/api/sessions/") && !m.captures.empty? && !Session.valid_id?(m.captures.first)
            return error_response(404, "not_found", "Session not found: #{m.captures.first.to_s[0, 80]}")
          end

          return session_route(principal) { send(handler, req, *m.captures) } if kind == :session

          return send(handler, req, *m.captures)
        end
        # Anything else is a file under public_dir (/assets/*, /public/* or
        # a bare path such as /style.css), or 404.
        serve_static(req)
      rescue Toolkit::Refused => e
        # A new session (create, continue, fork, review) on a config kit
        # with an invalid groups: (Toolkit.check_new!), whichever handler
        # spawned it.
        error_response(400, "toolkit_refused", e.message)
      rescue StandardError => e
        Log.exception(:web, "request_failed", e, method: env["REQUEST_METHOD"], path: env["PATH_INFO"])
        # A participant never reads an exception's words (they may name a
        # host path): the log has them.
        error_response(500, "internal_error", owner_env?(env) ? e.message : "chi web failed on this request")
      end

      # Whether the request's principal is the owner (none yet: the gate
      # didn't pass, so not a participant either).
      def owner_env?(env) = env[PRINCIPAL_ENV].nil? || env[PRINCIPAL_ENV].owner?

      # A :session route's handler: the ArgumentError its session lookup
      # raises (Session.load, the manager's find) is a 404 not_found with
      # its message. Only these routes: elsewhere an ArgumentError is a bug,
      # #route's 500. A handler's own rescues run first.
      def session_route(principal = nil)
        yield
      rescue ArgumentError => e
        # A participant's 404 never carries the lookup's words (a path).
        error_response(404, "not_found", principal.nil? || principal.owner? ? e.message : "Session not found")
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

      # The payload's capabilities (Capabilities, per request) and, next to
      # them, editor_url: the URL template a ref opens (web.editor), nil
      # when this viewer can't open one.
      def viewer_capabilities(req)
        editor_url = @editor_url && local_viewer?(req) ? @editor_url : nil
        { capabilities: Capabilities.for(@markdown_renderer, editor: !editor_url.nil?).to_h, editor_url: editor_url }
      end

      # A viewer on this machine, whose editor can open the session's
      # paths: a loopback peer, or this Mac on its own LAN address (the LAN
      # URL or its QR code opened here). The phone isn't. An SSH tunnel or
      # a local reverse proxy looks like loopback too (a known gap), unless
      # it leaves a trace and web.public_url is set (#proxied?).
      def local_viewer?(req)
        return false if proxied?(req)

        peer = req.get_header("REMOTE_ADDR").to_s
        LOOPBACK_PEERS.include?(peer) || (!@lan.nil? && peer == @lan[:ip])
      end

      LOOPBACK_NAMES = %w[127.0.0.1 [::1] localhost].freeze
      LOOPBACK_PEERS = %w[127.0.0.1 ::1 ::ffff:127.0.0.1].freeze

      # Only 127.0.0.1 / [::1] / localhost (any port), and in LAN mode the
      # LAN address, are answered. The socket is bound to those, but a Host
      # check stops DNS-rebinding pages. It reads the raw Host header:
      # Rack's req.host trusts X-Forwarded-Host, which such a page could
      # set. A request with no Host (HTTP/1.0) is answered only for a
      # loopback peer. With web.public_url its host (with its port, exactly)
      # is answered too.
      def local_host_header?(env)
        host = env["HTTP_HOST"].to_s
        return LOOPBACK_PEERS.include?(env["REMOTE_ADDR"].to_s) if host.empty?
        return true if @public_url&.host?(host)

        name = host.downcase.sub(/:\d*\z/, "")
        LOOPBACK_NAMES.include?(name) || (!@lan.nil? && name == @lan[:ip])
      end

      TOKEN_COOKIE = "chi_token"
      # The owner's cookie holds the token, but on the LAN a loopback
      # peer's holds Token.loopback_cookie (#owner_cookie_value): a cookie
      # for 127.0.0.1 goes to every server on any of its ports (a dev
      # server that logs headers), and that value works nowhere else.
      # 400 days, the longest a browser keeps a cookie (Chrome's cap). No
      # Secure: the LAN page is plain http. Lax, not Strict: a token link
      # opened from another site (a web messenger) makes its 303 chain
      # cross-site, and a Strict cookie wouldn't ride on the redirected GET;
      # the cross-site check already refuses what Strict would add.
      TOKEN_COOKIE_ATTRIBUTES = "HttpOnly; SameSite=Lax; Path=/; Max-Age=34560000"
      REFUSED_LOG_INTERVAL = 60.0
      REFUSED_LOG_KEYS = 256

      # Where #route keeps the request's Principal for its handlers.
      PRINCIPAL_ENV = "samagotchi.principal"
      PAGE_PATHS = ["/", "/index.html"].freeze
      # POST {code} or {token}: the page trades a link's one-time code (its
      # #code= fragment, token_fragment.js) or a pasted token (the 401 page's
      # form) for the cookie.
      TOKEN_TRADE_PATH = "/api/token"
      TRADE_BODY_LIMIT = 4096
      # Exact paths served before the token gate (still after the Host,
      # cross-site and frame checks), none holding a secret: the 401 page's
      # fragment trade script, and what a Home Screen app fetches without
      # the cookie (Chrome fetches a manifest without credentials): the
      # manifest, the service worker and the icons (Web Push).
      GATE_FREE_PATHS = ["/token_fragment.js", "/manifest.webmanifest", "/sw.js", "/apple-touch-icon.png",
                         "/icons/chi-180.png", "/icons/chi-192.png", "/icons/chi-512.png"].freeze

      # The request's Principal, as #route resolved it.
      def principal(req) = req.env.fetch(PRINCIPAL_ENV)

      # LAN mode: every route needs the access token, from a phone and from
      # this machine's loopback too (a pair participant's shell runs here),
      # as the chi_token cookie or an Authorization: Bearer header; only
      # GATE_FREE_PATHS and chi's token-less /api/info probe
      # (ProxyGate#probe_info?) are answered without it. The page with
      # ?token= (or a link's #code=, POST /api/token) trades it for the
      # cookie and a 303 to itself without it, so the token doesn't stay in
      # the browser's history.
      # @return [Array(Principal, nil), Array(nil, Array)] the request's
      #   principal (#principal_for), or the response that refuses it
      def token_gate(req)
        principal = principal_for(req)
        return [nil, refused_token(req)] if principal.nil?

        # The cookie gets the participant's grant's token, or the owner's
        # cookie value (the loopback one on the LAN's 127.0.0.1).
        if token_trade?(req)
          token = req.env[GRANT_TOKEN_ENV] || owner_cookie_value(req)
          return [nil, token_redirect(req, token)] unless fragment_trade?(req)
          return [nil, form_trade_redirect(req, token)] if form_post?(req)

          return [nil, token_cookie_response(req, token)]
        end

        [principal, nil]
      end

      # Who the request is, from the token it presents (the page's ?token=
      # on a trade, else the Bearer header or the cookie): the owner for
      # the access token; a participant for a live grant's token (a chp_
      # one, looked up only when no owner token was given), wherever the
      # request comes from, this machine's loopback too; with neither, the
      # owner only on a chi web that asks no token (loopback only: no LAN
      # mode, no web.public_url), else nil. The owner's cookie on the LAN's
      # loopback is the loopback value (#loopback_cookie: it stands for the
      # token in +given+). An ended or unknown grant's
      # token is nil anywhere: it never falls back to the owner.
      # @return [Principal, nil]
      # With web.public_url (ProxyGate) every request needs a token, and a
      # proxied one is #proxied_principal's.
      def principal_for(req)
        given = presented_tokens(req)
        return proxied_principal(req, given) if proxied?(req)
        return Principal::OWNER if (@lan || @public_url) && owner_token?(given)

        grant_tokens = given.select { |value| Grants.token?(value) }
        return Principal::OWNER if grant_tokens.empty? && !token_required?(req)

        participant_principal(req, grant_tokens)
      end

      # With web.public_url a request from this machine that didn't come
      # through the proxy (curl, chi's own callers) presents the Bearer
      # header only: no cookie, and no trade that would set one. A cookie for
      # 127.0.0.1 goes to every server on any of its ports. A LAN peer
      # (web.host lan) keeps the LAN's token link and cookie; a loopback
      # peer of a LAN chi web reads its cookie through #loopback_cookie.
      def presented_tokens(req)
        return [traded_token(req)] if token_trade?(req)
        return [bearer_token(req)] if direct_public?(req)

        cookie = req.cookies[token_cookie_name(req)]
        [bearer_token(req), loopback_cookie_peer?(req) ? loopback_cookie(cookie) : cookie]
      end

      # A loopback peer of a LAN chi web, whose owner cookie holds the
      # loopback value. With web.public_url, #direct_public? takes the
      # Bearer only. A request with a proxy's trace (one the user forwards
      # to loopback by hand) is the LAN's: a leaked loopback value must not
      # work from off this machine through it.
      def loopback_cookie_peer?(req)
        !@lan.nil? && @public_url.nil? && LOOPBACK_PEERS.include?(req.get_header("REMOTE_ADDR").to_s) &&
          !proxy_trace?(req.env)
      end

      # What a trade sets as the owner's cookie.
      def owner_cookie_value(req)
        loopback_cookie_peer?(req) ? Token.loopback_cookie(current_token) : current_token
      end

      # A loopback peer's cookie: the loopback value stands for the owner's
      # token, a grant's chp_ token is itself, and anything else, the token
      # itself included (a 0.130.0 cookie, #refused_token clears it), is
      # nothing.
      def loopback_cookie(value)
        return current_token if token_match?(value, Token.loopback_cookie(current_token))

        Grants.token?(value) ? value : nil
      end

      def direct_public?(req)
        !@public_url.nil? && LOOPBACK_PEERS.include?(req.get_header("REMOTE_ADDR").to_s) && !proxied?(req)
      end

      # The token a trade presents: the page's ?token=, or POST /api/token's
      # body's (read once): its token, or the token a one-time link code
      # stands for (LinkCodes#redeem: used up here, whatever the gate says,
      # but for a grant's code bound to another identity: decision C, kept
      # for the right one, and refused token_bound, #code_token).
      def traded_token(req)
        return req.params["token"] unless fragment_trade?(req)

        req.env.fetch(TRADED_TOKEN_ENV) do
          raw = request_body(req, TRADE_BODY_LIMIT).to_s
          value = if raw.bytesize >= TRADE_BODY_LIMIT then nil
                  elsif form_post?(req) then Rack::Utils.parse_query(raw)
                  else parse_json(raw)
                  end
          value = {} unless value.is_a?(Hash)
          req.env[TRADED_TOKEN_ENV] = value.key?("code") ? code_token(req, value["code"]) : string_or_nil(value["token"])
        end
      end

      def string_or_nil(value) = value.is_a?(String) ? value : nil

      # A bound grant's code is checked before it is used up: presented by
      # another identity, or not through the proxy, it stays (the one it was
      # sent to can still open it) and the trade is refused token_bound.
      def code_token(req, code)
        kind, token = @link_codes.redeem(code) do |found_kind, found_token|
          found_kind == :owner || code_identity_ok?(req, found_token)
        end
        kind == :owner ? current_token : token
      end

      def code_identity_ok?(req, token)
        grant = @grants.lookup(token)
        # No grant to check it against (deleted, left out of a newer store,
        # a store that doesn't read): kept, the trade refused.
        return false if grant.nil?
        return true unless grant.identity

        proxied = proxied?(req)
        state, identity = proxied ? proxy_identity(req) : [:none, nil]
        identity = nil unless state == :ok
        return true if bound_ok?(grant, identity, proxied)

        refuse_bound(req, grant, identity)
        false
      end

      TRADED_TOKEN_ENV = "samagotchi.traded_token"

      def fragment_trade?(req) = req.post? && req.path_info == TOKEN_TRADE_PATH

      # The 401 page's paste box, posted as a form (no script needed).
      def form_post?(req) = req.media_type == "application/x-www-form-urlencoded"

      def owner_token?(given) = given.any? { |value| token_match?(value, current_token) }

      # The cookie a request's token rides in, its name and attributes per
      # request: a proxied request's is ProxyGate::SECURE_COOKIE, Secure (the
      # public URL is https). A browser may hold both.
      def token_cookie_name(req) = proxied?(req) ? SECURE_COOKIE : TOKEN_COOKIE

      def token_cookie_attributes(req)
        proxied?(req) ? "Secure; #{TOKEN_COOKIE_ATTRIBUTES}" : TOKEN_COOKIE_ATTRIBUTES
      end

      def token_cookie(req, value)
        "#{token_cookie_name(req)}=#{value}; #{token_cookie_attributes(req)}"
      end

      def cleared_token_cookie(req)
        "#{token_cookie_name(req)}=; #{token_cookie_attributes(req).sub(/Max-Age=\d+/, "Max-Age=0")}"
      end

      # Whether the gate asks this request for a token: on a chi web on the
      # LAN or behind a proxy, every request does, this machine's loopback
      # too. Only a loopback-only chi web takes loopback as the owner.
      def token_required?(_req) = !(@public_url || @lan).nil?

      # The page opened with ?token= (a gated request, or a grant's token
      # anywhere): its token is traded for the cookie, whatever else the
      # request carries.
      # POST /api/token is the same trade for a token the page found in its
      # URL's fragment.
      def token_trade?(req)
        return false if direct_public?(req)

        # Through the proxy no GET trade (a ?token= rides the sign-in
        # redirect, and a crafted link would swap the owner's cookie): a
        # link's #code= and the 401 page's POST do it.
        page = req.get? && PAGE_PATHS.include?(req.path_info) && req.params.key?("token") && !(@public_url && proxied?(req))
        return false unless page || fragment_trade?(req)

        token_required?(req) || Grants.token?(traded_token(req))
      end

      # The 401 for a request #principal_for refused: an ended grant's, else
      # unauthorized. On a peer the gate doesn't ask, a grant's cookie that
      # no longer works is cleared too, so the browser it was left in (the
      # owner's, who opened a participant link) is the owner's again. A
      # LAN chi web's loopback peer whose cookie is the token itself (set
      # before the loopback value) has it cleared, so it stops riding to
      # the other local ports.
      def refused_token(req)
        response = grant_bound_response(req) || grant_ended_response(req) || unauthorized(req)
        cookie = req.cookies[token_cookie_name(req)]
        stale = loopback_cookie_peer?(req) && token_match?(cookie, current_token)
        return response unless stale || (!token_required?(req) && Grants.token?(cookie))

        status, headers, body = response
        [status, headers.merge("Set-Cookie" => cleared_token_cookie(req)), body]
      end

      def bearer_token(req) = req.get_header("HTTP_AUTHORIZATION").to_s[/\ABearer +(\S+)\z/, 1]

      def current_token
        token = @lan ? @lan[:token] : @public_token
        token.respond_to?(:current) ? token.current : token
      end

      def token_match?(given, token)
        return false if given.nil? || given.empty? || token.nil? || token.empty?

        Rack::Utils.secure_compare(given, token)
      end

      # The same page (and its other parameters, as they were written), the
      # token traded for the cookie. Proxied, the Location is absolute from
      # web.public_url: WEBrick would make a relative one absolute from the
      # first X-Forwarded-Host/-Proto, which a client sets through
      # oauth2-proxy (an open redirect).
      def token_redirect(req, token)
        query = req.query_string.split("&").reject { |pair| pair.split("=", 2).first == "token" }.join("&")
        location = query.empty? ? req.path_info : "#{req.path_info}?#{query}"
        location = "#{@public_url.origin}#{location}" if proxied?(req)
        [303, { "Location" => location, "Set-Cookie" => token_cookie(req, token),
                "Cache-Control" => "no-store", "Content-Length" => "0" }, []]
      end

      # The paste box's trade: the cookie and a 303 to the page (absolute
      # from web.public_url when proxied, as #token_redirect).
      def form_trade_redirect(req, token)
        location = proxied?(req) ? "#{@public_url.origin}/" : "/"
        [303, { "Location" => location, "Set-Cookie" => token_cookie(req, token), "Cache-Control" => "no-store",
                "Content-Length" => "0" }, []]
      end

      # The fragment trade's answer: the cookie, no body.
      def token_cookie_response(req, token)
        [204, { "Set-Cookie" => token_cookie(req, token), "Cache-Control" => "no-store" }, []]
      end

      # POST /api/token past the gate without a trade (nothing to trade here:
      # no token is asked of this request): nothing to do.
      def handle_token(_req) = [204, { "Cache-Control" => "no-store" }, []]

      def handle_update(req)
        return error_response(503, "no_hub", "this chi web has no session hub") unless @hub

        raw = request_body(req, 16_385)
        return error_response(413, "body_too_large", "update request is too large") if raw.bytesize > 16_384

        payload = parse_json(raw)
        return error_response(400, "invalid_update", "expected a JSON object with a version") unless payload.is_a?(Hash)

        version = payload["version"]
        # Gem::Version.correct? lets surrounding whitespace through; argv gets none.
        unless version.is_a?(String) && !version.match?(/\s/) && Gem::Version.correct?(version)
          return error_response(400, "invalid_version", "version must be a gem version")
        end

        version = Gem::Version.new(version).to_s
        if Gem::Version.new(version) <= Gem::Version.new(VERSION)
          return error_response(409, "update_not_newer", "version #{version} is not newer than this chi")
        end

        # Found out here, not from the hub: UpdateCheck (off with update.notify: off) is what tells it.
        blocked = @update_blocked.call
        return json_response(409, { error: "update_blocked", reason: blocked }) if blocked

        already_running = @update_mutex.synchronize do
          if @update_running
            true
          else
            @update_running = true
            false
          end
        end
        return error_response(409, "update_running", UPDATE_RUNNING) if already_running

        @hub.publish_update(state: "running", rows: [], operation: "install", version: version)
        Thread.new { perform_update(version) }
        json_response(202, { state: "running", version: version })
      rescue ThreadError => e
        @update_mutex.synchronize { @update_running = false }
        Log.warn(:web, "update_start_failed", error: e.class.name, msg: e.message)
        @hub&.publish_update(state: "failed", rows: [
          { "component" => "chi update", "status" => "failed (couldn't start update)", "failed" => true, "kept" => [] }
        ], operation: "install")
        error_response(503, "update_start_failed", "couldn't start chi update")
      end

      # The chi update child: with a chi home, the home's chi (its gem dirs
      # are what new workers activate); else this Ruby and the wrapper.
      def update_argv(version, home: ChiHome.current)
        args = ["update", "--to", version, "--no-desktop", "--json"]
        return home.boot_argv(run: ChiHome::CHI_BOOT) + ["--", *args] if home

        [RbConfig.ruby, InstalledGem.wrapper, *args]
      end

      def perform_update(version)
        argv = update_argv(version)
        said = nil
        output, success = @update_runner.call(argv, env: ChildEnv.unbundled,
                                              progress: lambda { |line|
                                                said = line unless line.strip.empty?
                                                @hub.publish_update(state: "running", rows: [], progress: line,
                                                                    operation: "install", version: version)
                                              })
        rows = update_rows(output)
        # No rows (a usage error, a refusal): what the child said is the reason.
        raise UpdateFailed, said || output.lines.map(&:strip).find { |line| !line.empty? } || "chi update printed no rows" unless rows

        # The installed version as of now (the hub's own look is up to a probe interval old), before "done".
        @hub.refresh_installed if success
        @hub.publish_update(state: success ? "done" : "failed", rows: rows, operation: "install", version: version)
      rescue StandardError => e
        Log.exception(:web, "update_failed", e)
        @hub.publish_update(state: "failed", rows: [
          { "component" => "chi update", "status" => "failed (#{e.message.lines.first.to_s.strip})",
            "failed" => true, "kept" => [] }
        ], operation: "install", version: version)
      ensure
        @update_mutex.synchronize { @update_running = false }
      end

      # chi update's own words when it printed no rows.
      class UpdateFailed < StandardError; end

      # chi update --json's rows, or nil when it printed none.
      def update_rows(output)
        rows = JSON.parse(output)
        rows if rows.is_a?(Array) && rows.all?(Hash)
      rescue JSON::ParserError
        nil
      end

      def run_update_command(argv, env:, progress:)
        Open3.popen3(env, *argv) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          stderr_thread = Thread.new { stderr.each_line { |line| progress.call(line.chomp) } }
          output = stdout.read
          stderr_thread.value
          [output, wait_thread.value.success?]
        end
      end

      def handle_restart_workers(_req)
        return error_response(503, "no_hub", "this chi web has no session hub") unless @hub

        already_running = @update_mutex.synchronize do
          if @update_running
            true
          else
            @update_running = true
            false
          end
        end
        return error_response(409, "update_running", UPDATE_RUNNING) if already_running

        @hub.publish_update(state: "running", rows: [], operation: "workers")
        Thread.new { perform_worker_restarts }
        json_response(202, { state: "running" })
      rescue ThreadError => e
        @update_mutex.synchronize { @update_running = false }
        Log.warn(:web, "worker_restart_start_failed", error: e.class.name, msg: e.message)
        @hub&.publish_update(state: "failed", rows: [
          { "state" => "failed", "reason" => "couldn't start worker restarts" }
        ], operation: "workers")
        error_response(503, "restart_start_failed", "couldn't start worker restarts")
      end

      def perform_worker_restarts
        # Installed now: the hub's own look is up to a full probe old (nil right after chi web started).
        target = @hub.refresh_installed || VERSION
        rows = []
        LiveVersions.stale_workers(target, state_dir: default_state_dir).each do |worker|
          row = begin
            restarted = @manager.restart_session(worker.session_id, state_dir: @state_dir, client_id: ClientId::WEB_RESTART)
            @hub.touch(worker.session_id)
            { "session_id" => restarted.session_id, "state" => "restarted", "from_version" => restarted.from_version,
              "version" => restarted.version }
          rescue SessionManager::RestartRefused => e
            # detail: the refusal's own words (RestartRefused.words), the reason code for clients.
            { "session_id" => worker.session_id, "state" => "refused", "reason" => e.reason.to_s,
              "detail" => e.message, "holds" => e.holds.map(&:to_s) }
          rescue SessionManager::OwnedByTUI => e
            { "session_id" => worker.session_id, "state" => "owned_by_tui", "detail" => e.message }
          rescue StandardError => e
            Log.exception(:web, "worker_restart_failed", e, sid: worker.session_id)
            { "session_id" => worker.session_id, "state" => "failed", "reason" => e.class.name, "detail" => e.message }
          end
          rows << row
          @hub.publish_update(state: "running", rows: rows.dup, operation: "workers")
        end
        state = rows.any? { |row| row["state"] == "failed" } ? "failed" : "done"
        @hub.publish_update(state: state, rows: rows, operation: "workers")
      rescue StandardError => e
        Log.exception(:web, "worker_restart_failed", e)
        @hub.publish_update(state: "failed", rows: [
          { "state" => "failed", "reason" => e.class.name, "detail" => e.message }
        ], operation: "workers")
      ensure
        @update_mutex.synchronize { @update_running = false }
      end

      # The exec replaces this process: an update's chi update child (its
      # pipes read here) or a worker restart pass would die mid-way, so
      # neither may run, and none starts once the restart is asked for.
      def handle_restart_web(_req)
        return error_response(503, "restart_unavailable", "chi web cannot restart itself in this process") unless @restart_web

        busy = @update_mutex.synchronize do
          next true if @update_running

          @update_running = true # held for good once restarting: the exec ends this process
          false
        end
        return error_response(409, "update_running", UPDATE_RUNNING) if busy

        case @restart_web.call
        when true then return json_response(202, { state: "restarting" })
        when :no_wrapper
          refusal = error_response(409, "restart_unavailable", "no chi wrapper to restart into (installed with --bindir?); " \
                                                               "restart chi web in its terminal")
        else refusal = error_response(409, "restart_requested", "chi web is already restarting")
        end
        @update_mutex.synchronize { @update_running = false }
        refusal
      end

      def unauthorized(req)
        reason = req.env[REFUSED_ENV]
        log_refused(refused_peer(req), req.path_info, reason)
        return error_response(401, "unauthorized", unauthorized_detail(req, reason)) if req.path_info.start_with?("/api/")

        body = unauthorized_page(req)
        [401, { "Content-Type" => "text/html; charset=utf-8", "Content-Length" => body.bytesize.to_s, "Cache-Control" => "no-store" },
         [body]]
      end

      # Which page a refused page request gets: the LAN page with no
      # web.public_url, the proxy page for a request that came through it,
      # and for a browser on this machine the one pointing at the public
      # address (#direct_public?): there the paste box can't help.
      def unauthorized_page(req)
        return direct_public_page if direct_public?(req)
        return PUBLIC_UNAUTHORIZED_PAGE if @public_url

        UNAUTHORIZED_PAGE
      end

      # A browser on this machine, with web.public_url set: the gate refuses
      # it like every other request, and no trade can fix it here — loopback
      # takes the token as Bearer only, so there is no cookie for it to keep
      # (a cookie for 127.0.0.1 reaches every server on any local port). The
      # page says where to open chi web instead. The origin is this machine's
      # config, not a secret; it is escaped all the same, and no token or
      # link code is in it.
      def direct_public_page
        origin = CGI.escapeHTML(@public_url.origin)
        <<~HTML
          <!doctype html>
          <html lang="en"><head><meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>chi web: open it at its public address</title>
          <style>
            :root { color-scheme: light dark; }
            body { font: 16px/1.5 -apple-system, system-ui, sans-serif; max-width: 30rem; margin: 3rem auto; padding: 0 1rem; }
            a { color: inherit; }
          </style></head>
          <body>
          <h1>chi web</h1>
          <p>chi web is behind an access proxy, so every request needs its access token, this machine's too.
          A browser here can't trade a token for a cookie on 127.0.0.1, so this page can't let you in: open
          chi web at its public address instead.</p>
          <p><a href="#{origin}/">#{origin}/</a></p>
          <p>chi web prints a link to it in its terminal every time it starts.</p>
          </body></html>
        HTML
      end

      def unauthorized_detail(req, reason)
        return "chi web behind the proxy: #{reason || "needs its access token"}" if proxied?(req)

        unless @public_url
          here = LOOPBACK_PEERS.include?(req.get_header("REMOTE_ADDR").to_s)
          return "chi web on the LAN needs its access token#{", on this machine too" if here}"
        end

        detail = "chi web with web.public_url needs its access token, on this machine too"
        direct_public?(req) ? "#{detail}; open its public address #{@public_url.origin}/ instead" : detail
      end

      # Who a refusal is logged as: the peer, or behind a proxy (every peer
      # 127.0.0.1) the client: its identity, else the X-Forwarded-For hop the
      # proxy appended (the last one).
      def refused_peer(req)
        return req.get_header("REMOTE_ADDR").to_s unless proxied?(req)

        identity = @public_url.identity_env && req.env[@public_url.identity_env]
        hop = req.get_header("HTTP_X_FORWARDED_FOR").to_s.split(",").last.to_s.strip
        "proxy:#{[identity.to_s.strip, hop].find { |v| !v.empty? } || "?"}"[0, 200]
      end

      # At most once a minute per peer: a phone with an old link retries.
      # At most REFUSED_LOG_KEYS peers a minute (rotating headers can't
      # fill the log).
      def log_refused(peer, path, reason = nil)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        due = @refused_mutex.synchronize do
          @refused_logged.delete_if { |_, at| now - at >= REFUSED_LOG_INTERVAL } if @refused_logged.size > 64
          next false if @refused_logged.size >= REFUSED_LOG_KEYS && !@refused_logged.key?(peer)

          last = @refused_logged[peer]
          (last.nil? || now - last >= REFUSED_LOG_INTERVAL).tap { |fresh| @refused_logged[peer] = now if fresh }
        end
        Log.warn(:web, "unauthorized", peer: peer, path: path, **(reason ? { reason: reason } : {})) if due
      end

      # Behind a proxy (web.public_url) the paste box posts the token in the
      # body (POST /api/token): a GET would put it in the URL, the proxy's
      # access log and the history. On this machine the page opens through
      # the proxy too.
      def self.public_unauthorized_page(page)
        page.sub('<form method="get" action="/">', '<form method="post" action="/api/token">')
            .sub("Open the link chi web printed in its terminal (Local on this machine, LAN, or\nProxied behind an auth proxy), or scan its QR code.",
                 "Open the Proxied link chi web printed in its terminal (it works once; chi web again prints a new " \
                 "one), or paste the token from its web-token file.")
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
        <p>This page needs chi web's access token. Open the link chi web printed in its terminal (Local on this machine, LAN, or
        Proxied behind an auth proxy), or scan its QR code.</p>
        <p id="trade" hidden></p>
        <form method="get" action="/">
          <label for="token">Or paste the token:</label>
          <input id="token" name="token" autocomplete="off" autocapitalize="off" spellcheck="false">
          <button type="submit">Open</button>
        </form>
        <script type="module">
          import { tradeFragmentCode } from "/token_fragment.js";
          tradeFragmentCode({ onRefused: (words) => {
            const line = document.getElementById("trade");
            line.textContent = words;
            line.hidden = false;
          } });
        </script>
        </body></html>
      HTML
      PUBLIC_UNAUTHORIZED_PAGE = public_unauthorized_page(UNAUTHORIZED_PAGE).freeze
      private_class_method :public_unauthorized_page

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
        foreign ||= !origin.nil? && !same_origin?(env, origin.downcase)
        return false unless foreign

        !%w[GET HEAD].include?(env["REQUEST_METHOD"]) || env["PATH_INFO"].to_s.start_with?("/api/")
      end

      # The page's own origin: through the proxy only web.public_url's
      # (https), else http://<Host> (or the public origin).
      def same_origin?(env, origin)
        return origin == @public_url.origin if @public_url && proxied?(Rack::Request.new(env))

        origin == "http://#{env["HTTP_HOST"].to_s.downcase}" || public_origin?(origin)
      end

      # The page served through web.public_url (Origin https://<public host>).
      def public_origin?(origin) = !@public_url.nil? && origin.downcase == @public_url.origin

      def cross_origin
        error_response(403, "cross_origin", "requests from other websites are refused")
      end

      def forbidden
        names = ["127.0.0.1", "[::1]", "localhost", @lan && @lan[:ip], @public_url&.host].compact
        names = "#{names[0..-2].join(", ")} and #{names.last}"
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

      def handle_projects(req)
        return error_response(503, "no_hub", "this chi web has no session hub") unless @hub

        dir, error = scope_dir(req.params["dir"])
        return error if error

        current_root = dir && ProjectScope.root_for(dir)
        json_response(200, ProjectList.build(@hub.snapshot, start_dir: start_dir, current_root: current_root))
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
      # is chi web, and it knows ?dir (features). Its chi version state is
      # {version, installed, available, update_blocked}; newest_workers: the
      # workers it starts run that one, not this chi web's version;
      # session_commands: the routes chi --remote needs
      # (SessionAccessRoutes::FEATURE); remote_attach: the ones a remote
      # attached TUI needs (ATTACH_FEATURE); bound_grants: an invite takes an
      # identity (BOUND_FEATURE). lan: its LAN address, nil when it listens
      # on loopback only; proxy: {identity_header} behind an auth proxy
      # (web.public_url or a tunnel; the header nil when none is trusted),
      # nil without one: the Invite dialog's email field and chi share's
      # warning. A participant gets app, version and features only
      # (#participant_info).
      def handle_info(req)
        return participant_info unless principal(req).owner?

        chi_state = @hub&.chi_state || { version: Samagotchi::VERSION, installed: nil, available: nil, update_blocked: nil }
        json_response(200, { app: "chi-web", **chi_state, pid: Process.pid,
                             cwd: Dir.pwd, start_dir: start_dir, features: INFO_FEATURES, lan: @lan && @lan[:ip],
                             proxy: @public_url && { identity_header: @public_url.identity_header } })
      end

      # POST …/participants takes an identity (a grant bound to it): a chi
      # web without it would ignore one and issue an unbound grant, so chi
      # --remote share --identity asks for this first.
      BOUND_FEATURE = "bound_grants"
      INFO_FEATURES = ["dir", "newest_workers", SessionAccessRoutes::FEATURE, SessionAccessRoutes::ATTACH_FEATURE,
                       BOUND_FEATURE].freeze

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
        toolkits = toolkits_listing(registry)
        payload[:toolkits] = toolkits if toolkits
        json_response(200, payload)
      end

      # Kits the web never offers: the participants' boundary, a delegate
      # child's, and ToolkitSuggest's defer sentinel.
      PICKER_HIDDEN_KITS = [Toolkit::REVIEW, Toolkit::CHILD, "undecided"].freeze

      # The start page's toolkit picker: {default:, suggest:, kits: [{name,
      # description?}]}. Built-in and config kits only (a bundle's load in
      # the worker), less PICKER_HIDDEN_KITS and any kit a new session would
      # refuse (Toolkit.check_new!) or that doesn't resolve (a base that is a
      # bundle kit); the configured default always listed, first when it
      # isn't one of them. +suggest+: "on" only when the worker would ask
      # (toolkit.suggest.mode on, a System 1 host, at least 2 described
      # candidates), else the mode ("audit") or "off". nil when it can't be
      # read: the picker stays hidden.
      def toolkits_listing(registry)
        default = Toolkit.configured.name
        config = Toolkit.config_kits
        kits = Toolkit.kits(config: config)
        listed = kits.values.filter_map do |kit|
          next if PICKER_HIDDEN_KITS.include?(kit.name) || !ToolkitSuggest.resolves?(kit.name, kits)
          next unless new_session_kit?(kit.name, config)

          kit.description.to_s.empty? ? { name: kit.name } : { name: kit.name, description: kit.description }
        end
        listed.unshift({ name: default }) if listed.none? { |kit| kit[:name] == default }
        { default: default, suggest: toolkit_suggest_mode(registry, kits, default), kits: listed }
      rescue StandardError => e
        Log.warn(:web, "toolkits_listing_failed", error: e.class.name, msg: e.message)
        nil
      end

      def new_session_kit?(name, config)
        Toolkit.check_new!(Toolkit.new(name: name), config: config)
        true
      rescue Toolkit::Refused
        false
      end

      def toolkit_suggest_mode(registry, kits, default)
        mode = Config.get("toolkit.suggest.mode").to_s.strip.downcase
        return mode == "audit" ? "audit" : "off" unless mode == "on"
        return "off" if ToolkitSuggest.candidates(kits, default_name: default).size < 2
        return "off" unless SystemOne::Client.from_config(host_registry: registry, mode: "on", tag: :toolkit)

        "on"
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
          add_thinking(model, target, names, settings)
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

      # The thinking level +model+ starts at, with where it came from (the
      # start page's think chip; SettingExplained#summary, no session).
      def add_thinking(model, target, names, settings)
        model[:thinking] = Thinking.explain(target, names: names, models: settings).summary
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
        # Not the route's own 403 (a parent's option refused): the worker
        # asked for a secret this chi web didn't send.
        return error_response(502, BridgeSecret::ERROR, BridgeSecret.refused(id)) if reply.secret_refused?

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
        error_response(503, "not_live", WorkerLink.not_live(id))
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

      # The session's Bridge, waiting briefly for one a resume just spawned.
      # @return [BridgeClient, nil]
      def live_bridge_client(id)
        link = worker_link(id)
        link = await_worker_link(id, timeout: [@bridge_wait_timeout.to_f, 5.0].min) unless link.live?
        link_client(id, link)
      end

      # The process holding the session (an OwnerLock::Owner), or nil. A worker always runs a Bridge; a TUI (plain `chi`) doesn't share.
      def session_owner(id)
        @manager.session_owner(id, state_dir: @state_dir)
      rescue StandardError
        nil
      end

      # ── The working set (web.working_set) ───────────────────────────────

      # GET /api/sessions/:id/working_set: the working set as the model has
      # it ({items:, at:, running:}, WorkingSet), what the page overlays on its rows'
      # set when it seeds a session's and when the expanded view opens (a
      # file changed while the session sat idle). A live worker's snapshot
      # messages are the truth, as #handle_show's, else the file's; the
      # strategy is the session's llm ctx chip's, the folder its working
      # directory. running: a turn runs. The snapshot's messages lag it, so
      # the answer is then the turn's last :working_set_updated (the
      # snapshot's working_set, TurnAccumulator#working_set); before the
      # turn emitted one, or from an older worker without the field, it is
      # the session's messages, behind that turn's events, and the page
      # keeps theirs (working_set.js newerSnapshot).
      def handle_working_set(_req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        live = bridge_get_json(id, "snapshot")
        running = !live&.dig("snapshot", "current_turn").nil?
        turn_set = running && running_working_set(live["snapshot"]["working_set"])
        return json_response(200, turn_set.merge(running: true)) if turn_set

        messages = live_or_saved(live && live["snapshot"], "messages") { session.messages }
        # A snapshot's entries have string keys (paired_runs reads symbols).
        messages = Array(messages).map { |message| message.is_a?(Hash) ? message.transform_keys(&:to_sym) : message }
        llm_context = SessionSetting::LLM_CONTEXT.snapshot_value(live && live["session_state_snapshot"]) do
          SessionSetting::LLM_CONTEXT.saved_summary(session, registry: host_registry)
        end
        snapshot = WorkingSet.build(messages, cwd: session.working_directory, strategy: working_set_strategy(llm_context),
                                    pins: session.working_set_pins)
        json_response(200, snapshot.to_h.merge(running: running))
      end

      # The running turn's set from a worker's snapshot ({"items", "at"}), as
      # {items:, at:}; nil when it has none (none emitted yet, an older worker).
      def running_working_set(set)
        return nil unless set.is_a?(Hash) && set["items"].is_a?(Array) && set["at"].is_a?(Integer)

        { items: set["items"], at: set["at"] }
      end

      # The strategy an llm ctx chip names ("none", "stale,forget"), as
      # LLMContextView takes it; none when there is no chip.
      def working_set_strategy(llm_context)
        named = llm_context.is_a?(Hash) ? (llm_context[:strategy] || llm_context["strategy"]).to_s : ""
        layers = named.split(",").map(&:strip).reject { |layer| layer.empty? || layer == "none" }
        layers.empty? ? LLMContextView::NONE : layers.map(&:to_sym)
      end

      # ── Attached context (ContextSources): the session bar's chips ───────
      # A source's command isn't shown (the page may be on a phone over the
      # LAN), and the web adds a URL only, through an installed bundle's
      # provider (ContextProviders): never a command.

      # GET /api/sessions/:id/context: the sources this session sees, muted
      # ones marked, with what the chips show, never a command. ?full=1
      # (chi context ls from another machine, SessionAccess::Remote): each
      # source as it was added too, its command included (#context_row), and
      # a project's source a session's own of its name shadows, marked
      # shadowed.
      def handle_context_list(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        own = ContextSources.session_location(id, state_dir: default_state_dir)
        subs = own.subscriptions
        full = truthy_param?(req.params["full"])
        rows = attached_context(session, shadowed: full).map { |attached| context_row(attached, own, subs, full: full) }
        json_response(200, { session_id: id, sources: rows, can_add_url: ContextProviders.any? })
      end

      # GET /api/sessions/:id/context/:name: one source with its text
      # (?full=1: as the list's).
      def handle_context_show(req, id, name)
        session = @session_class.load(id, state_dir: default_state_dir)
        attached = find_context(session, name) or return error_response(404, "context_missing", "no source #{name[0, 40]}")
        own = ContextSources.session_location(id, state_dir: default_state_dir)
        row = context_row(attached, own, own.subscriptions, full: truthy_param?(req.params["full"]))
        json_response(200, row.merge(text: attached.snapshot.text))
      end

      # POST /api/sessions/:id/context: a source attached to this session.
      # {url, why, hint}: the one an installed bundle's provider makes of
      # +url+ (the page's only kind). As chi context add: {name, push: true,
      # why, hint}, a source chi context push fills, or {name, cmd, every,
      # why, hint}, a command chi runs every so often. added_by: "cli" or
      # "agent" (chi context's), else "web". 201 {status: "attached", name};
      # 400 invalid_json or invalid_source (a bad name or every), 422
      # not_a_url or no_provider, 409 exists.
      def handle_context_add(req, id)
        session = @session_class.load(id, state_dir: default_state_dir)
        body = parse_json(request_body(req))
        return error_response(400, "invalid_json", CONTEXT_ADD_BODIES) unless body.is_a?(Hash)
        return context_add_named(id, body) if body.key?("name")
        return error_response(400, "invalid_json", CONTEXT_ADD_BODIES) unless body["url"].is_a?(String)

        url = body["url"].strip
        return error_response(422, "not_a_url", "give an http(s) URL") unless url.match?(%r{\Ahttps?://\S+\z})

        resolved = ContextProviders.resolve(url)
        return error_response(422, "no_provider", "no installed bundle resolves #{url[0, 200]}") unless resolved

        own = ContextSources.session_location(session.id, state_dir: default_state_dir)
        own.add(web_source(resolved, body, own.scope))
        json_response(201, { status: "attached", name: resolved.name })
      rescue ContextProviders::Invalid => e
        error_response(422, "no_provider", e.message)
      rescue ContextSources::Invalid => e
        error_response(409, "exists", e.message)
      end

      CONTEXT_ADD_BODIES = "give {url, why}, {name, push: true, why, hint} or {name, cmd, every, why, hint}"

      # A --push or --cmd source (chi context add NAME), checked as chi
      # context checks it, attached through SessionAccess::Local.
      def context_add_named(id, body)
        name, cmd, push, every = body.values_at("name", "cmd", "push", "every")
        unless name.is_a?(String) && ((push == true) ^ cmd.is_a?(String)) && (every.nil? || every.is_a?(Integer))
          return error_response(400, "invalid_json", CONTEXT_ADD_BODIES)
        end
        return error_response(400, "invalid_source", "every is for a cmd source") if push && every
        return error_response(400, "invalid_source", "cmd is empty") if cmd && cmd.strip.empty?

        source = begin
          ContextSources.check_name!(name)
          ContextSources::Source.new(name: name, cmd: cmd, every_seconds: ContextSources.check_every!(every),
                                     why: context_line(body["why"]), hint: context_line(body["hint"]), scope: nil,
                                     added_by: context_added_by(body), created_at: Time.now.utc.iso8601)
        rescue ContextSources::Invalid => e
          return error_response(400, "invalid_source", e.message)
        end
        session_access.context_add(context_target(id), source)
        json_response(201, { status: "attached", name: name })
      end

      def context_line(value) = ContextSources.one_line(value.is_a?(String) ? value : nil, ContextSources::LINE_MAX_CHARS)
      def context_added_by(body) = %w[cli agent].include?(body["added_by"]) ? body["added_by"] : "web"

      def web_source(resolved, body, scope)
        ContextSources::Source.new(name: resolved.name, cmd: resolved.cmd, every_seconds: resolved.every_seconds,
                                   why: context_line(body["why"]) || resolved.why,
                                   hint: context_line(body["hint"]) || resolved.hint, scope: scope,
                                   added_by: context_added_by(body), created_at: Time.now.utc.iso8601,
                                   provider: resolved.bundle)
      end

      # DELETE /api/sessions/:id/context/:name: the session's own source is
      # detached; a project's is muted for this session only (the page's
      # ×). With ?own=1 (chi context rm) only the session's own is
      # detached: a project's is 409 project_source, as chi context rm
      # refuses it.
      def handle_context_delete(req, id, name)
        return context_remove_own(id, name) if truthy_param?(req.params["own"])

        session = @session_class.load(id, state_dir: default_state_dir)
        attached = find_context(session, name) or return error_response(404, "context_missing", "no source #{name[0, 40]}")
        if attached.location.session?
          attached.location.remove(attached.name)
          json_response(200, { status: "detached", name: attached.name })
        else
          ContextSources.session_location(id, state_dir: default_state_dir).mute(attached.name)
          json_response(200, { status: "muted", name: attached.name })
        end
      end

      def context_remove_own(id, name)
        case session_access.context_remove(context_target(id), name)
        when :removed then json_response(200, { status: "detached", name: name })
        when :project
          error_response(409, "project_source", ContextCommand.project_source_message(name))
        else error_response(404, "context_missing", "no source #{name[0, 40]}")
        end
      rescue ContextSources::Invalid
        error_response(404, "context_missing", "no source #{name[0, 40]}")
      end

      def attached_context(session, shadowed: false)
        ContextSources.attached(session.id, project_root: session.project_root, state_dir: default_state_dir,
                                            shadowed: shadowed)
      end

      # @return [ContextSources::Attached, nil]
      def find_context(session, name)
        ContextSources.check_name!(name)
        attached_context(session).find { |attached| attached.name == name }
      rescue ContextSources::Invalid
        nil
      end

      # A source's row: what the page's chips show. +full+ (chi context ls
      # and show from another machine, SessionAccess::Remote): also the
      # source as it was added (source: Source#to_h, its command too) and
      # the snapshot (Snapshot#to_h without its text), and shadowed.
      def context_row(attached, own, subs, full: false)
        source = attached.source
        snapshot = attached.snapshot
        row = { name: source.name, scope: source.scope, kind: source.push? ? "push" : "cmd", every_seconds: source.every_seconds,
                why: source.why, hint: snapshot.hint || source.hint, summary: snapshot.summary, error: snapshot.error,
                fetched_at: snapshot.fetched_at, has_text: snapshot.text?, muted: own.muted?(source.name),
                unread: snapshot.text? && subs[source.name]&.read != snapshot.revision }
        return row unless full

        row.merge(source: source.to_h, snapshot: snapshot.to_h.except("text", :text), shadowed: attached.shadowed)
      end

      def handle_stream(req, id)
        # Validate session exists
        begin
          @session_class.load(id, state_dir: default_state_dir)
        rescue ArgumentError
          return error_response(404, "not_found", "Session not found: #{id}")
        end

        link = worker_link(id)
        if link.is_a?(WorkerLink::Starting)
          return error_response(503, "not_live", format(LaunchMode::BRIDGE_LATE, id)) if link.stuck

          link = await_worker_link(id, timeout: [@bridge_wait_timeout.to_f, 2.0].min)
        end
        return stream_link_error(id, link) unless link.live?

        client = link_client(id, link)
        filter = stream_filter(req, id)
        query = participant_view?(req) ? participant_stream_query(req) : stream_query(req)
        opened = client.open_stream(query: query, last_event_id: req.env["HTTP_LAST_EVENT_ID"])
        return stream_open_error(id, opened) unless opened.is_a?(BridgeClient::StreamOpen::Opened)

        handed_off = false
        begin
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
            hijack = sse_hijack(id, req, client, opened, filter)
            handed_off = true
            return [200, headers.merge("rack.hijack" => hijack), []]
          end

          body = proxy_stream_body(id, req, client, opened, filter)
          handed_off = true
          [200, headers, body]
        ensure
          opened.sock.close unless handed_off
        end
      end

      # The one ProxyStreamBody both of #handle_stream's transports send:
      # the session's Bridge stream, through the request principal's frame
      # filter (#stream_filter).
      def proxy_stream_body(_id, req, client, opened, filter)
        query = participant_view?(req) ? participant_stream_query(req) : stream_query(req)
        ProxyStreamBody.new(client: client, opened: opened, query: query, headers: req.env,
                            server_running: stream_running(principal(req)), filter: filter)
      end

      # What a request's stream goes through on its way from the Bridge:
      # nil, the raw bytes unchanged, for the owner; a participant's (and
      # the owner's ?as=participant, the participant view) goes through
      # ParticipantStreamFilter. A filter is anything with #call(chunk) ->
      # String (nil or "" sends nothing); see ProxyStreamBody.
      def stream_filter(req, id)
        return nil unless participant_view?(req)

        participant_stream_filter(req, id)
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

      # The stream's query as the worker's Bridge gets it ("?..." or ""):
      # every parameter but `raw`. `?raw=1` is the worker port's debugging view
      # (a chunk's provider payload); a browser never gets it through here.
      # Keys are compared decoded, as the Bridge reads them.
      def stream_query(req)
        pairs = req.query_string.to_s.split("&").reject do |pair|
          URI.decode_www_form_component(pair.split("=", 2).first.to_s) == "raw"
        rescue ArgumentError
          false
        end
        pairs.empty? ? "" : "?#{pairs.join("&")}"
      end

      # Rack hijack lambda (env["rack.hijack?"] truthy): pipes the bridge's SSE
      # frames directly to the client socket until it disconnects. The handler
      # (WEBrick via rackup) has already sent the status line + headers, so
      # only body bytes go to the socket here.
      def sse_hijack(id, req, client, opened, filter)
        # Made before the status line goes out: a principal with no filter
        # is refused (#stream_filter), never streamed.
        body = proxy_stream_body(id, req, client, opened, filter)
        lambda do |io|
          body.each { |chunk| io.write(chunk) }
        rescue Errno::EPIPE, Errno::ECONNRESET, IOError
          nil # client went away — end the stream quietly
        rescue StandardError => e
          Log.warn(:web, "proxy_failed", sid: id, port: client.port, error: e.class.name, msg: e.message)
          nil
        ensure
          body.close
        end
      end

      # Bounded wait for a freshly-spawned worker's Bridge so the response
      # hands the client a live transport without client-side polling (the
      # web's WorkerLink.await: #worker_link polled). Returns the first Live,
      # else the last outcome (None when +timeout+ allows no wait): the
      # session still exists; EventSource auto-reconnect covers late binders.
      # @return [WorkerLink::Live, WorkerLink::None, WorkerLink::Stale]
      def await_worker_link(session_id, timeout: @bridge_wait_timeout)
        return WorkerLink::None.new if timeout.nil? || timeout <= 0

        WorkerLink.await(session_id, session_dir: @session_class.session_dir(session_id, state_dir: default_state_dir),
                         timeout: timeout, interval: BridgeClient::SPAWN_POLL_INTERVAL,
                         give_up: lambda do |outcome|
                           outcome.is_a?(WorkerLink::Leaving) || outcome.is_a?(WorkerLink::Stale) ||
                             outcome.is_a?(WorkerLink::Skew) ||
                             (outcome.is_a?(WorkerLink::Starting) && outcome.stuck)
                         end)
      end

      def stream_link_error(id, link)
        return error_response(502, "worker_newer", link.message(id)) if link.is_a?(WorkerLink::Skew)
        if link.is_a?(WorkerLink::Starting) && link.stuck
          return error_response(503, "not_live", format(LaunchMode::BRIDGE_LATE, id))
        end
        if link.is_a?(WorkerLink::Leaving)
          return json_response(503, { error: "not_live", detail: WorkerLink.not_live(id),
                                      leaving: true, leave_seconds: link.left.round(1) })
        end

        error_response(503, "not_live", WorkerLink.not_live(id))
      end

      def stream_open_error(id, outcome)
        return error_response(503, "not_live", WorkerLink.unanswered(id)) if outcome.is_a?(BridgeClient::StreamOpen::Unreachable)
        return error_response(503, "not_live", WorkerLink.not_live(id)) if outcome.reason == :unknown_session
        return error_response(502, BridgeSecret::ERROR, BridgeSecret.refused(id)) if outcome.reason == :bridge_secret

        error_response(502, "bridge_error", outcome.detail || "the session's worker answered #{outcome.status}")
      end

      # The session's worker link (WorkerLink.resolve; stale sidecars are
      # removed): read again for every request, so a respawned worker's port
      # and secret are the ones used.
      # @return [WorkerLink::Live, WorkerLink::None, WorkerLink::Stale]
      def worker_link(session_id)
        dir = @session_class.session_dir(session_id, state_dir: default_state_dir)
        WorkerLink.resolve(dir, unlink: true)
      rescue StandardError
        WorkerLink::None.new
      end

      # @return [BridgeClient, nil] a client for the session's live Bridge
      def bridge_client(session_id) = link_client(session_id, worker_link(session_id))

      # @return [BridgeClient, nil] +link+'s client when it is Live
      def link_client(session_id, link) = link.live? ? link.client(session_id, host: DEFAULT_HOST) : nil

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
        return participant_shell(req) if participant_view?(req)

        path = File.join(@public_dir, "index.html")
        if File.file?(path)
          # A block: a preset's \& or \' is text, never a backreference.
          body = File.read(path).sub("<body>") { "<body #{index_data_attributes(req)}>" }
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
        when ".png" then "image/png"
        when ".webmanifest" then "application/manifest+json"
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

      # The folder chi web starts in (StartDir), the cwd when none was given.
      def start_dir = @start_dir || Dir.pwd

      # The sessions folder as the page shows it: ~ for the home folder.
      def sessions_dir_label
        home_label(File.expand_path(default_state_dir))
      end

      def home_label(dir) = Paths.tilde(dir)

      # <body> data for the page: where sessions are stored, where an
      # all-view new chat starts (the start folder), the home folder, and,
      # when ?dir names a folder in a repo, that project's name and root. A
      # bad dir adds nothing here: the list call answers 400 and the page
      # says so.
      # Without ?dir (and without ?scope=all) the page is the start folder's
      # project view when that folder is in a repo: data-scope-dir names it
      # for the page (the URL stays bare, so a token's 303, a link code's
      # #code= and the app's start_url "/" all land there). ?dir= beats
      # ?scope=all.
      def index_data_attributes(req)
        # version: the chi that served the page; the events snapshot names
        # the one serving now (an upgraded chi web after a reconnect).
        attrs = { "sessions-dir" => sessions_dir_label, "server-dir" => home_label(start_dir), "version" => Samagotchi::VERSION }
        # The owner's home: a claim link's quote reads it "~", as the
        # participant page shows it (claim_link.js).
        attrs["home"] = Dir.home
        attrs["view"] = view_name(req.params["view"])
        # Only when on: the page reads its presence (the turn view ignores it).
        attrs["working-set"] = "1" if working_set?(req.params["working_set"])
        attrs.merge!(annotate_presets_data)
        dir, = scope_dir(req.params["dir"])
        unless dir
          dir = default_scope_dir(req)
          attrs["scope-dir"] = dir if dir
        end
        root = dir && ProjectScope.root_for(dir)
        if root
          attrs["project-name"] = File.basename(root)
          attrs["project-dir"] = home_label(root)
        elsif dir.nil?
          # The all view's way back: the project view it came from
          # (?from=), else the project chi web starts in.
          back, = scope_dir(req.params["from"])
          back ||= start_dir
          if (back_root = ProjectScope.root_for(back))
            attrs["back-name"] = File.basename(back_root)
            attrs["back-dir"] = back
          end
        end
        body_data(attrs)
      end

      # +attrs+ as <body> data attributes, each value escaped.
      def body_data(attrs) = attrs.map { |key, value| %(data-#{key}="#{Rack::Utils.escape_html(value)}") }.join(" ")

      # The Annotate presets (web.annotate_presets) for a page's <body>, the
      # owner's and the participant page's. Always there: an empty one means
      # no presets, not the default.
      def annotate_presets_data = { "annotate-presets" => @annotate_presets }

      # The folder a bare page (no ?dir, no ?scope=all) is scoped to: the
      # start folder when it is still a folder in a repo, else nil (every
      # session).
      def default_scope_dir(req)
        return nil unless req.params["dir"].to_s.strip.empty?
        return nil if req.params["scope"] == "all"

        dir = File.expand_path(start_dir)
        File.directory?(dir) && ProjectScope.root_for(dir) ? dir : nil
      end

      VIEWS = Config::BY_KEY["web.view"].enum_values

      # The view for this page load: ?view=stage|turn wins, anything
      # else leaves the config's choice (web.view).
      def view_name(param)
        VIEWS.include?(param) ? param : @view
      end

      # The working set for this page load: ?working_set=1|0 wins, anything
      # else leaves the config's choice (web.working_set).
      def working_set?(param)
        case param
        when "1" then true
        when "0" then false
        else @working_set
        end
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
          @chi_state = @hub.chi_state
        end

        def each
          # The page compares this full chi state with the one it was served by.
          snapshot = { sessions: @snapshot }.merge(@chi_state)
          update_state = @hub.update_state
          snapshot[:chi_update] = update_state if update_state
          yield frame(nil, "snapshot", snapshot)
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
      # Ctrl-C of chi web. Without a +filter+ the bytes go through unchanged
      # (the owner's stream); with one, each chunk read from the Bridge goes
      # through it, and what it returns is sent.
      class ProxyStreamBody
        # @param headers [Hash] the request's Rack env; only its Last-Event-ID
        #   is kept (the env carries the token cookie, never held or inspected)
        # @param filter [#call, nil] chunk -> String (nil or "": nothing sent);
        #   it sees the Bridge's reads as they come, not whole frames
        # @param client [BridgeClient] the session's Bridge (App#link_client)
        # @param opened [BridgeClient::StreamOpen::Opened] the socket whose
        #   200 was answered to the caller
        def initialize(client:, opened:, query:, headers:, server_running: -> { true }, filter: nil)
          @client = client
          @opened = opened
          @query = query
          @last_event_id = headers["HTTP_LAST_EVENT_ID"]
          @server_running = server_running
          @filter = filter
        end

        def each(&)
          opened = @opened
          return unless opened

          @client.read_stream(opened, running: @server_running) do |chunk|
            out = @filter ? @filter.call(chunk) : chunk
            yield(out) unless out.nil? || out.empty?
          end
        ensure
          @opened = nil
        end

        def close
          opened = @opened
          @opened = nil
          opened&.sock&.close
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
