# frozen_string_literal: true

require_relative "../session"
require_relative "../session_access/local"
require_relative "../session_inbox"
require_relative "../reply_wait"
require_relative "../pending_question"
require_relative "../context_sources"
require_relative "../context_command"
require_relative "../send_command"
require_relative "../launch_mode"
require_relative "../model_profile"
require_relative "../client_id"
require_relative "../children_status"
require_relative "../session_metrics"

module Samagotchi
  module Web
    # The routes chi's session commands need from another machine's chi web
    # (chi --remote NAME …, SessionAccess::Remote), one per
    # SessionAccess::Local operation that the page's own routes don't cover:
    # a prefix resolved, the CLI's list rows, a wait's pre-send state and
    # the wait itself, a note, a push into a context source. Each calls
    # SessionAccess::Local, so a Remote maps 1:1 onto them. Included in
    # App: its ROUTES name the handlers, and its helpers (json_response,
    # parse_json, …) answer. See docs/architecture.md (chi web's routes for
    # the session commands).
    module SessionAccessRoutes
      # A wait route answers within this many seconds (status timeout); the
      # client asks again until its own --timeout.
      WAIT_MAX_SECONDS = 30.0
      # GET /api/info's feature: this chi web has these routes (a remote
      # client checks it before its first session command).
      FEATURE = "session_commands"
      # GET /api/info's feature: this chi web has the routes a remote
      # attached TUI needs (wake, worker; chi --remote NAME --attach).
      ATTACH_FEATURE = "remote_attach"
      # The longest POST …/wake waits for a worker's Bridge
      # (TerminalUI::AttachLauncher::BRIDGE_WAIT, an attach's here).
      WAKE_MAX_WAIT = 10.0

      private

      # This server's sessions, as a session command reaches them here.
      def session_access = @session_access ||= SessionAccess::Local.new(state_dir: @state_dir)

      # A refusal an exception carries: its stable +code+, +detail+ (what
      # the page shows; the message by default), and for a remote client
      # the exception's own message and the fields its class is built from
      # (session_id, reason, …), so it can raise the same class.
      def refusal_response(status, code, error, detail: error.message, **fields)
        json_response(status, { error: code, detail: detail, message: error.message, **fields }.compact)
      end

      # The body as a Hash ({} when there is none), or nil when it isn't one.
      def body_hash(req)
        raw = request_body(req)
        return {} if raw.to_s.strip.empty?

        parsed = parse_json(raw)
        parsed.is_a?(Hash) ? parsed : nil
      end

      def truthy_param?(value) = %w[1 true yes].include?(value.to_s.strip.downcase)

      # GET /api/sessions/resolve?id=PREFIX: the full id of the session an id
      # or a unique prefix names (SessionAccess::Local#resolve). 200 {id};
      # 404 not_found; 400 ambiguous_id with ids (the sessions it names).
      def handle_resolve(req)
        given = req.params["id"].to_s
        return error_response(404, "not_found", "no session #{given[0, 80]}") unless Session.valid_id?(given)
        return participant_resolve(principal(req).grant, given) unless principal(req).owner?

        json_response(200, { id: session_access.resolve(given) })
      rescue Session::AmbiguousId => e
        refusal_response(400, "ambiguous_id", e, ids: e.ids)
      rescue ArgumentError
        error_response(404, "not_found", "no session #{given[0, 80]}")
      end

      # GET /api/sessions/:id?brief=1: the session as a session command
      # reads it (SessionAccess::Local#show): the file's status (not the
      # displayed one), its names, folder, model and parent_answers, its
      # owner's kind, and the file's pending question, never its messages.
      # A chi web from before ?brief answers the whole read, which has the
      # session part too.
      def handle_brief_read(id)
        session = @session_class.load(id, state_dir: default_state_dir)
        owner = session_access.owner(id)
        json_response(200, {
          brief: true,
          session: { id: session.id, status: session.status, title: session.title,
                     display_title: session.display_title, project_root: session.project_root,
                     working_directory: session.working_directory, model_name: session.model_name,
                     model_typed: session.model_typed, parent_answers: session.parent_answers,
                     owner: owner&.kind },
          pending_question: session.pending_question&.to_file
        })
      end

      # GET /api/sessions/summaries: the rows chi sessions list prints
      # (SessionManager.session_summaries: status, live, busy, owner, recap,
      # ctx_pct, waiting, …), filtered as its flags filter. Params: dir (a
      # folder: its project's sessions; none: every project's), cwd (in that
      # folder or below), live=1, archived=1, tests=0 (leave test runs out),
      # sort, order, limit. An array, newest first by default.
      def handle_summaries(req)
        dir, error = scope_dir(req.params["dir"])
        return error if error

        cwd = req.params["cwd"].to_s
        cwd = nil if cwd.strip.empty?
        return error_response(400, "invalid_cwd", "cwd is an absolute path: #{cwd[0, 200]}") if cwd && !cwd.start_with?("/")

        rows = session_access.summaries(
          live: truthy_param?(req.params["live"]), cwd: cwd, limit: sanitize_limit(req.params["limit"]),
          include_tests: !%w[0 false no].include?(req.params["tests"].to_s.strip.downcase),
          project_root: dir && ProjectScope.root_for(dir), include_archived: truthy_param?(req.params["archived"]),
          sort: sanitize_sort(req.params["sort"]), order: sanitize_order(req.params["order"])
        )
        json_response(200, rows)
      end

      # POST /api/sessions/:id/wait/prepare: what chi send --wait and chi
      # answer read before anything is sent (SessionAccess::Local#
      # prepare_wait). Body (all optional): question_id (the question the
      # baseline counts as reported; absent: the one pending now, null:
      # none), turn (--turn: known_turn says whether it can be waited for),
      # created (a session just created: no reply, no question), busy (chi
      # send --wait with a message: refuse a running turn, 409 busy or
      # waiting in SendCommand::Busy's words, with its fields: question,
      # parent_strategy; queue: true, --queue, refuses only a waiting
      # question). 200 {session_id, cursor, baseline:
      # {messages, question_id, last_turn}, own_turn, known_turn, running,
      # live, settled, last_turn_id}.
      def handle_wait_prepare(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        turn = body["turn"]
        return error_response(400, "invalid_turn", "turn is a turn id") unless turn.nil? || turn.is_a?(String)
        return participant_wait_prepare(req, id, body) unless principal(req).owner?

        session = session_access.show(id)
        if body["busy"] == true
          owner = session_access.owner(id) if session.status == Session::STATUS_RUNNING
          busy = SendCommand::Busy.for(session, owner: owner, queue: body["queue"] == true)
          return json_response(409, busy_json(busy)) if busy
        end

        question_id = body.key?("question_id") ? body["question_id"]&.to_s : :pending
        start = session_access.prepare_wait(id, session: session, question_id: question_id, turn: turn,
                                                created: body["created"] == true)
        json_response(200, wait_start_json(id, start))
      end

      # A Busy refusal: its words here, and its fields, which a chi --remote
      # client words with its own commands (SessionAccess::Remote#busy).
      def busy_json(busy)
        { error: busy.error, detail: busy.message, message: busy.message, session_id: busy.session_id,
          question: busy.question&.to_file, parent_strategy: (strategy_json(busy.strategy) if busy.strategy) }.compact
      end

      def strategy_json(strategy) = { name: strategy.name, allowed: strategy.allowed, origin: strategy.origin.to_s }

      def wait_start_json(id, start)
        { session_id: id, cursor: start.cursor, baseline: start.baseline.to_h, own_turn: start.own_turn,
          known_turn: start.known_turn, running: start.running, live: start.live, settled: start.settled,
          last_turn_id: start.last_turn_id }
      end

      # POST /api/sessions/:id/wait: ReplyWait for at most WAIT_MAX_SECONDS
      # (SessionAccess::Local#wait_reply). Body: cursor, baseline
      # ({messages, question_id, last_turn}, as the prepare route gave it),
      # turn, queued, ended_before, owner_grace (seconds, null: wait for
      # whatever wakes a worker), timeout (seconds, capped), running_look
      # (the last timeout's, as it came). 200: the ReplyWait::Result's
      # fields (status: done, waiting_for_answer, no_reply, error, stopped,
      # timeout or worker_gone; text, file, question, outcome, …; never the
      # Session) and parent_strategy, what a parent may pick on the
      # session's questions here (ParentReport.strategy_for). A timeout
      # status: ask again, with its running_look ({last_end, claimed}, or
      # null: the running turn this slice saw, so a settle between two
      # slices still ends the wait). 503 server_stopping when chi web stops
      # mid-wait.
      def handle_wait(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        options, error = wait_options(body)
        return error if error
        return participant_wait(req, id, options) unless principal(req).owner?

        session_access.show(id)
        result = session_access.wait_reply(id, **options, poll_interval: @wait_poll_interval,
                                               cancelled: -> { !@server_running.call })
        return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

        json_response(200, wait_result_json(result, session_access.parent_strategy(id)))
      end

      # The wait's ReplyWait arguments from the body: [options, nil] or
      # [nil, a 400 response].
      def wait_options(body)
        strings = %w[cursor turn].to_h { |key| [key, body[key]] }
        if strings.any? { |_, value| !value.nil? && !value.is_a?(String) }
          return [nil, error_response(400, "invalid_wait", "cursor and turn are strings")]
        end

        baseline, error = wait_baseline(body["baseline"])
        return [nil, error] if error

        numbers = %w[timeout owner_grace].to_h { |key| [key, body[key]] }
        if numbers.any? { |_, value| !value.nil? && !(value.is_a?(Numeric) && value.positive?) }
          return [nil, error_response(400, "invalid_wait", "timeout and owner_grace are positive seconds")]
        end

        timeout = [numbers["timeout"] || WAIT_MAX_SECONDS, WAIT_MAX_SECONDS].min
        look = body["running_look"]
        running_look = look.nil? ? nil : ReplyWait::RunningLook.from_h(look)
        if !look.nil? && running_look.nil?
          return [nil, error_response(400, "invalid_wait", "running_look is {last_end, claimed: [file names]}")]
        end

        [{ cursor: strings["cursor"], turn: strings["turn"], baseline: baseline, timeout: timeout,
           owner_grace: numbers["owner_grace"], queued: body["queued"] == true, ended_before: body["ended_before"] == true,
           running_look: running_look }, nil]
      end

      def wait_baseline(raw)
        return [nil, nil] if raw.nil?

        fields = { "messages" => Integer, "question_id" => String, "last_turn" => String }
        unless raw.is_a?(Hash) && raw.all? { |key, value| fields.key?(key) && (value.nil? || value.is_a?(fields[key])) }
          return [nil, error_response(400, "invalid_wait", "baseline is {messages, question_id, last_turn}")]
        end

        [ReplyWait::Baseline.new(**raw.transform_keys(&:to_sym)), nil]
      end

      RESULT_FIELDS = %i[text file outcome limit error_kind retryable cancel_reason stopped_by kept_steps turn_id origin].freeze

      def wait_result_json(result, strategy)
        json = { status: result.status.to_s }
        RESULT_FIELDS.each { |key| json[key] = result[key] }
        json[:text] = json[:text]&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        json[:question] = result.question&.to_file
        json[:running_look] = result.running_look&.to_h
        json[:parent_strategy] = strategy_json(strategy)
        json
      end

      # POST /api/sessions/:id/wake {wait}: the session's worker for a remote
      # attach (SessionAccess::Local#wake): the live one, else resumed and
      # waited for up to +wait+ seconds (WAKE_MAX_WAIT, also the most). 200
      # {session_id, woke, worker: {epoch, started_at, version, features},
      # model_name, default_model (this machine's config, for the TUI's
      # status row), parent_strategy, installed (the newest chi here)}. A
      # worker still leaving is waited for first (Local#wake: its recap's
      # timeout and a margin, on top of +wait+); 409
      # owned_by_tui (a chi REPL has it), 409 scratch (a leftover scratch
      # session, as chi --attach here says); 504 worker_timeout (its Bridge
      # didn't come in time); 404 not_found.
      def handle_wake(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        wait = body.fetch("wait", WAKE_MAX_WAIT)
        return error_response(400, "invalid_wait", "wait is positive seconds") unless wait.is_a?(Numeric) && wait.positive?

        woken = session_access.wake(id, wait: [wait, WAKE_MAX_WAIT].min)
        unless woken.sidecar
          late = format(LaunchMode::BRIDGE_LATE, id)
          return json_response(504, { error: "worker_timeout", detail: late, message: late, session_id: id })
        end

        json_response(200, { session_id: id, woke: woken.woke, worker: worker_json(woken.sidecar),
                             model_name: session_access.show(id).model_name,
                             default_model: ModelProfile.default_model_name,
                             parent_strategy: strategy_json(session_access.parent_strategy(id)),
                             installed: @hub&.installed })
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      rescue SessionAccess::Refused => e
        refusal_response(409, e.code, e, session_id: id)
      end

      # GET /api/sessions/:id/worker: the session's worker now, never
      # started (SessionAccess::Local#worker): a remote attach's
      # rediscovery and its features after a restart, and before its wake
      # whether the worker is leaving (its recap on leave: the wake waits
      # for it, so the client says so). 200 {session_id, live, stopped,
      # owner: worker|tui|null, leaving, leave_seconds (its leave's budget
      # left, nil unless leaving), worker: {epoch, started_at, version,
      # features}|null, default_model (this machine's config, as the
      # wake's), parent_strategy}; 404 not_found.
      def handle_worker(_req, id)
        state = session_access.worker(id)
        leaving = state.leaving?
        json_response(200, { session_id: id, live: state.live?, stopped: state.stopped, owner: state.owner&.kind,
                             leaving: leaving, leave_seconds: (state.owner.leave_left.round(1) if leaving),
                             worker: state.sidecar && worker_json(state.sidecar),
                             default_model: ModelProfile.default_model_name,
                             parent_strategy: strategy_json(session_access.parent_strategy(id)) })
      end

      # A live worker as a remote client knows it: its epoch is its
      # identity (the one in its event ids).
      def worker_json(sidecar)
        { epoch: sidecar.epoch, started_at: sidecar.started_at, version: sidecar.version, features: sidecar.features }
      end

      # POST /api/sessions/:id/exit {client_id, delete, stop}: a remote attached
      # TUI's /exit (and the worker's half of /exit --delete and /archive),
      # relayed to the live worker's exit (BridgeClient#request_exit; never
      # wakes one). client_id is passed on only when it is an attached TUI's
      # (tui:…): any other is dropped, and then every stream counts as a UI,
      # which only keeps the worker up. stop: true means the ask's "stop them
      # and exit". 200 the Bridge's {status: exiting, session_id, discard,
      # stopped}; 409 held with its {status, reason, tasks, hint, holds};
      # 503 not_live, 501 not_supported (an older worker), 504 worker_timeout.
      def handle_exit(req, id)
        body = body_hash(req) or return refusal(400, "invalid_json", "invalid JSON body")
        @session_class.load(id, state_dir: default_state_dir)
        client_id = body["client_id"] if body["client_id"].is_a?(String) && body["client_id"].start_with?(ClientId::TUI_PREFIX)
        delete = body["delete"] == true
        options = { delete: delete }
        options[:stop] = true if body["stop"] == "all"
        options[:ask] = false if body["ask"] == false

        request = ->(client) { client.request_exit(client_id: client_id, **options) }
        with_message(relay(id, bridge_client(id), request, what: "the worker was not asked to exit", cant: "exit from here") do |reply|
          case reply.status
          when 200 then json_response(200, reply.json || { status: "exiting", session_id: id })
          when 409
            held = reply.json || {}
            words = "the session's worker stays up (#{held["reason"] || "held"})"
            json_response(409, held.merge("error" => "held", "detail" => words, "message" => words, "session_id" => id))
          end
        end)
      end

      # POST /api/sessions/:id/recap: the saved recap, and a new one asked for
      # (BridgeClient#request_recap; it arrives on the stream as
      # :recap_ready). 200 the Bridge's {enabled, saved, request,
      # min_user_turns, session_off}; 503, 501, 504 as every relay.
      def handle_recap(_req, id)
        @session_class.load(id, state_dir: default_state_dir)
        request = lambda(&:request_recap)
        with_message(relay(id, bridge_client(id), request, what: "no recap was read", cant: "recap") do |reply|
          json_response(200, reply.json || {}) if reply.status == 200
        end)
      end

      # GET /api/sessions/:id/stats: the live worker's metrics for /stats
      # (its stats route; a worker from before it answers only its state's
      # metrics). 200 {session_id, metrics}; 503 not_live, 504
      # worker_timeout, 502 bridge_error.
      def handle_stats(_req, id)
        @session_class.load(id, state_dir: default_state_dir)
        client = bridge_client(id) or return with_message(not_live(id))

        status, json = client.get("stats")
        metrics = json["metrics"] if status == 200 && json.is_a?(Hash)
        if status == 404 && !(json.is_a?(Hash) && json["error"] == "unknown_session")
          status, json = client.get("state")
          metrics = json.dig("session_state_snapshot", "metrics") if status == 200 && json.is_a?(Hash)
        end
        return json_response(200, { session_id: id, metrics: metrics }) if status == 200
        return with_message(worker_timeout("the stats were not read")) if status.nil?
        return with_message(not_live(id)) if status == 404

        with_message(error_response(502, "bridge_error", "the stats were not read: the session's worker answered #{status}"))
      end

      # GET /api/sessions/:id/children/counts: the session's delegates'
      # counts (ChildrenStatus.counts, from their files here), a remote
      # TUI's status row segment. 200 {running, waiting, unreported}; 404.
      def handle_children_counts(_req, id)
        @session_class.load(id, state_dir: default_state_dir)
        json_response(200, ChildrenStatus.counts(id, state_dir: default_state_dir).to_h)
      end

      # A turn id as a session's prompts carry it (a uuid; any word-ish id).
      TURN_ID = /\A[\w.:-]{1,128}\z/

      # GET /api/sessions/:id/turns/:turn_id/records: a turn's saved tool
      # records and turn record (SessionMetrics, from analytics.json here),
      # as saved: what a remote TUI's join draws the steps' durations and a
      # failed turn's line from. 200 {tool_records: […], turn_record: {…} |
      # null}; 400 invalid_turn_id; 404 not_found.
      def handle_turn_records(_req, id, turn_id)
        return refusal(400, "invalid_turn_id", "not a turn id: #{turn_id.to_s[0, 80]}") unless TURN_ID.match?(turn_id)

        @session_class.load(id, state_dir: default_state_dir)
        dir = Session.session_dir(id, state_dir: default_state_dir)
        json_response(200, { tool_records: SessionMetrics.saved_tool_records(dir, turn_id),
                             turn_record: SessionMetrics.saved_turn_record(dir, turn_id) })
      end

      # {error, detail, message}: the words a remote client raises with.
      def refusal(status, code, words, **fields)
        json_response(status, { error: code, detail: words, message: words, **fields })
      end

      # A relay's error answer (#relay's {error, detail}) with its message
      # too, as a remote attach's routes answer every refusal.
      def with_message(response)
        status, _headers, chunks = response
        return response if status < 400

        body = JSON.parse(chunks.join)
        return response unless body.is_a?(Hash) && body["error"] && !body.key?("message")

        json_response(status, body.merge("message" => body["detail"]))
      rescue JSON::ParserError
        response
      end

      # POST /api/sessions/:id/notes {text, source}: a context note for the
      # session (NoteDelivery, as chi note; source: where it came from,
      # "cli" by default, never "broadcast"). 200 {status: "queued" (a
      # worker adds it) or "waits" (the next start does), session_id,
      # queued}; 409 owned_by_tui (status refused: a chi REPL has it); 400
      # note_rejected (empty, or over 16 KiB).
      def handle_notes(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        text = body["text"]
        source = body.fetch("source", "cli")
        return error_response(400, "missing_fields", "text is required") unless text.is_a?(String)
        return error_response(400, "invalid_source", "source is a word") unless source.is_a?(String) && !source.strip.empty?
        return error_response(400, "invalid_source", "source broadcast is chi broadcast's own") if source.strip == "broadcast"

        session_access.show(id)
        result = session_access.note(id, text: text, source: source.strip)
        if result.status == :refused
          error = SessionManager::OwnedByTUI.new(id)
          return refusal_response(409, "owned_by_tui", error, session_id: id, status: "refused", queued: 0)
        end

        json_response(200, { status: result.status.to_s, session_id: id, queued: result.queued })
      rescue SessionInbox::NoteRejected => e
        error_response(400, "note_rejected", e.message)
      end

      # POST /api/sessions/:id/context/:name/push {text, summary, wake,
      # hint}: new text for the session's --push source (chi context push;
      # the fields as a source's JSON output gives them, checked the same
      # way). 200 {status: "pushed", name, before, revision, changed}; 404
      # not_found (no such source); 409 not_push (a command source); 400
      # invalid_text.
      def handle_context_push(req, id, name)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        return error_response(400, "missing_fields", "text is required") unless body["text"].is_a?(String)

        fetched = begin
          ContextSources.parse_output(JSON.generate(body.slice("text", "summary", "wake", "hint")))
        rescue ContextSources::Invalid => e
          return error_response(400, "invalid_text", e.message)
        end
        pushed = session_access.context_push(context_target(id), name, fetched)
        case pushed.status
        when :missing then error_response(404, "not_found", "no source #{name[0, 40]}")
        when :not_push then error_response(409, "not_push", SessionAccess::ContextPush.not_push_message(name))
        else json_response(200, { status: "pushed", name: name, before: pushed.before, revision: pushed.revision,
                                  changed: pushed.before != pushed.revision })
        end
      rescue ContextSources::Invalid
        error_response(404, "not_found", "no source #{name[0, 40]}")
      end

      # The session as chi context's Target (SessionAccess::Local's context
      # calls take one).
      # @raise [ArgumentError] no such session
      def context_target(id)
        session = session_access.show(id)
        ContextCommand::Target.new(session_id: id, project_root: session.project_root, cwd: session.working_directory,
                                   label: id[0, 8])
      end
    end
  end
end
