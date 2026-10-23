# frozen_string_literal: true

require_relative "../session"
require_relative "../session_access/local"
require_relative "../session_inbox"
require_relative "../reply_wait"
require_relative "../pending_question"
require_relative "../context_sources"
require_relative "../context_command"
require_relative "../send_command"

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
      # waiting in SendCommand::Busy's words; queue: true, --queue, refuses
      # only a waiting question). 200 {session_id, cursor, baseline:
      # {messages, question_id, last_turn}, own_turn, known_turn, running,
      # live, settled, last_turn_id}.
      def handle_wait_prepare(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        turn = body["turn"]
        return error_response(400, "invalid_turn", "turn is a turn id") unless turn.nil? || turn.is_a?(String)

        session = session_access.show(id)
        if body["busy"] == true
          owner = session_access.owner(id) if session.status == Session::STATUS_RUNNING
          busy = SendCommand::Busy.for(session, owner: owner, queue: body["queue"] == true)
          return json_response(409, { error: busy.error, detail: busy.message, message: busy.message, session_id: id }) if busy
        end

        question_id = body.key?("question_id") ? body["question_id"]&.to_s : :pending
        start = session_access.prepare_wait(id, session: session, question_id: question_id, turn: turn,
                                                created: body["created"] == true)
        json_response(200, wait_start_json(id, start))
      end

      def wait_start_json(id, start)
        { session_id: id, cursor: start.cursor, baseline: start.baseline.to_h, own_turn: start.own_turn,
          known_turn: start.known_turn, running: start.running, live: start.live, settled: start.settled,
          last_turn_id: start.last_turn_id }
      end

      # POST /api/sessions/:id/wait: ReplyWait for at most WAIT_MAX_SECONDS
      # (SessionAccess::Local#wait_reply). Body: cursor, baseline
      # ({messages, question_id, last_turn}, as the prepare route gave it),
      # turn, queued, ended_before, owner_grace (seconds, null: wait for
      # whatever wakes a worker), timeout (seconds, capped). 200: the
      # ReplyWait::Result's fields (status: done, waiting_for_answer,
      # no_reply, error, stopped, timeout or worker_gone; text, file,
      # question, outcome, …; never the Session) and parent_strategy, what
      # a parent may pick on the session's questions here
      # (ParentReport.strategy_for). A timeout status: ask again. 503
      # server_stopping when chi web stops mid-wait.
      def handle_wait(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        options, error = wait_options(body)
        return error if error

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
        [{ cursor: strings["cursor"], turn: strings["turn"], baseline: baseline, timeout: timeout,
           owner_grace: numbers["owner_grace"], queued: body["queued"] == true, ended_before: body["ended_before"] == true }, nil]
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
        json[:parent_strategy] = { name: strategy.name, allowed: strategy.allowed, origin: strategy.origin.to_s }
        json
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
