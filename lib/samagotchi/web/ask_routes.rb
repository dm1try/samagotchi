# frozen_string_literal: true

require "delegate"
require_relative "../bridge_client"
require_relative "../agent_caller"
require_relative "../client_id"
require_relative "../reply_wait"
require_relative "../session"
require_relative "../session_command_catalog"
require_relative "../session_inbox"
require_relative "../turn_flow"
require_relative "../session_access/ask"
require_relative "../session_access/exchange"
require_relative "../session_access/exchange/token"
require_relative "../reply_for"
require_relative "../turn_anchors"
require_relative "request_body"

module Samagotchi
  module Web
    # The thin-client routes (docs/thin-clients.md): POST …/ask (one
    # message, its answer in one call: SessionAccess::Ask), a wait token for
    # POST …/wait (#handle_token_wait), wait: on POST …/answer
    # (#answer_wait_option, #answered_wait) and a create's token
    # (#create_token). Included in App through SessionAccessRoutes; its
    # helpers (json_response, body_hash, wait_result_json, busy_json,
    # parent_gate, owned_by_tui, refused_delivery, record_history, …) answer.
    module AskRoutes
      # One ask answers within this many seconds from its request's start,
      # whatever it waits for (a continue in flight, the Bridge of a worker
      # starting, the wait's slice): a proxy or a Shortcut with a 60 s limit
      # is safe. The post to a live worker draws on it too (#ask_bridge), but
      # never under POST_FLOOR, so a call ends within about 44 s.
      ASK_MAX_SECONDS = 35.0
      # The shortest read a post to a live worker gets (#ask_bridge),
      # however little of the deadline is left: a healthy but loaded worker
      # still reads the message in time.
      POST_FLOOR = 8.0
      # The fewest seconds the post's body deadline leaves before its read
      # times out (BridgeClient's deadline_margin): a worker that took the
      # turn just in time still has that long to answer 202, so a 504 means
      # it was not taken.
      POST_MARGIN = 2.5
      # A wait route answers within this many seconds (status timeout); the
      # client asks again until its own --timeout. SessionAccessRoutes'
      # (which includes this module) too.
      WAIT_MAX_SECONDS = 30.0
      # GET /api/info's feature: this chi web has the ask route, wait
      # tokens, the answer's wait and the create's token.
      ASK_FEATURE = "ask"
      # A line a worker may run as a session command (#ask_request_id): a
      # / name (Registry::UNKNOWN_COMMAND_WORD's shape, which every
      # built-in a worker runs and a bundle's COMMAND_NAME fits) followed by
      # whitespace or nothing, so "/Users/x/a.rb fails" is a message. A !
      # line is the shell's.
      COMMAND_SHAPE = %r{\A/[A-Za-z][A-Za-z0-9_-]*(?:\s|\z)}
      # An ask's request_id: 1 to 128 printable ASCII characters.
      REQUEST_ID = /\A[\x21-\x7e]{1,128}\z/
      # The wait body's own fields, which a token replaces.
      TOKEN_EXCLUDES = %w[cursor baseline turn queued ended_before owner_grace].freeze

      # The ask's backend: chi web's sessions (SessionAccess::Local),
      # delivering through chi web's own manager and Bridge as POST …/turn
      # does (the same Bridge wait and give-ups), and waiting at its poll
      # interval. One per request.
      class AskAccess < SimpleDelegator
        def initialize(access, manager:, bridge:, poll_interval: nil)
          super(access)
          @manager = manager
          @bridge = bridge
          @poll_interval = poll_interval
        end

        def deliver_turn(id, **)
          __getobj__.deliver_turn(id, **, manager: @manager, bridge: -> { @bridge.call(id) })
        end

        def wait_reply(id, **options)
          options = { poll_interval: @poll_interval }.merge(options) if @poll_interval
          __getobj__.wait_reply(id, **options)
        end
      end

      private

      # POST /api/sessions/:id/ask {prompt, timeout, queue, client_id,
      # request_id, reply_for}: the message delivered (to a chain's newest link; a
      # running session queues it as its own turn unless queue is false) and
      # its answer waited for, all within ASK_MAX_SECONDS. A request_id (a
      # message's, not a command's) names its turn: a retry whose turn the
      # session knows waits on it again, nothing sent and no second history
      # line (SessionAccess::Ask#call). A reply_for (ReplyFor.parse: a name
      # or the values) rides a message's turn as its anchor (a command's
      # runs as the command: kept in hand only). 200 wait_result_json's fields +
      # session_id (+ asked, the id given, when another link ran it; +
      # token when the status is timeout: POST …/wait {token} goes on; +
      # request_id when one was given); 200 {status: command} for a session
      # command. 404 not_found, 400 ambiguous_id / invalid_ask, 409 busy /
      # waiting / continuing / owned_by_tui / enqueued_id_conflict (the
      # same request_id, another prompt), the turn route's delivery
      # refusals, 503 server_stopping.
      def handle_ask(req, id)
        # One deadline from the request's start: the gate, the continue
        # waits, the Bridge wait and the slice all draw on it.
        deadline = ask_clock + ASK_MAX_SECONDS
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        prompt, client_id, options, error = ask_request(id, body)
        return error if error

        reply_for, error = ask_reply_for(body)
        return error if error

        options[:anchors] = TurnAnchors.new(reply_for: reply_for) if reply_for && !command_line?(prompt)

        gated = ask_gate(id, prompt, client_id)
        return gated if gated

        bridge = ->(sid) { ask_bridge(sid, deadline) }
        access = AskAccess.new(session_access, manager: @manager, bridge: bridge, poll_interval: @wait_poll_interval)
        stopping = -> { !@server_running.call }
        exchange = SessionAccess::Exchange.new(access, continuing_wait: [SessionAccess::Exchange::CONTINUING_WAIT,
                                                                         ASK_MAX_SECONDS].min, cancelled: stopping)
        outcome = SessionAccess::Ask.new(access, exchange: exchange)
                                    .call(id, prompt: prompt, client_id: client_id, cap: deadline - ask_clock,
                                              cancelled: stopping, **options)
        rebound = outcome.is_a?(SessionAccess::Ask::Reply) && outcome.rebound
        record_history(body, prompt) unless outcome.is_a?(SessionAccess::Ask::Refused) || rebound
        ask_response(id, outcome, request_id: options[:request_id], reply_for: reply_for)
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # The ask's body read: [prompt, client_id, {queue:, timeout:,
      # request_id:}, nil] or [.., a 400 response].
      def ask_request(id, body)
        return [nil, nil, nil, error_response(400, "missing_fields", "prompt is required")] unless body["prompt"].is_a?(String)

        prompt = SessionInbox.checked_text(body["prompt"], noun: "message")
        if (entry = SessionCommandCatalog.ui_only_entry(prompt))
          words = SessionCommandCatalog.ui_only_refusal(entry.name, id, runner: "ask")
          return [nil, nil, nil, error_response(400, "local_command", words)]
        end

        timeout = body.fetch("timeout", WAIT_MAX_SECONDS)
        unless timeout.is_a?(Numeric) && timeout.positive?
          return [nil, nil, nil, error_response(400, "invalid_ask", "timeout is positive seconds")]
        end

        queue = body.fetch("queue", true)
        return [nil, nil, nil, error_response(400, "invalid_ask", "queue is true or false")] unless [true, false].include?(queue)

        client_id = body["client_id"]
        return [nil, nil, nil, error_response(400, "invalid_ask", "client_id is a string")] unless client_id.nil? || client_id.is_a?(String)

        request_id, error = ask_request_id(body, prompt)
        return [nil, nil, nil, error] if error

        options = { queue: queue, timeout: [timeout, WAIT_MAX_SECONDS].min }
        options[:request_id] = request_id if request_id
        [prompt, ask_sender(client_id, prompt), options, nil]
      rescue SessionInbox::NoteRejected => e
        [nil, nil, nil, error_response(400, "invalid_prompt", e.message)]
      end

      # The body's reply_for: [nil or a ReplyFor, nil] or [nil, a 400
      # invalid_ask]. A name is resolved here (config.yml's surfaces:, read
      # now), so the session saves values: a later config edit leaves old
      # turns as they were.
      def ask_reply_for(body)
        [ReplyFor.parse(body["reply_for"]), nil]
      rescue ReplyFor::Invalid => e
        [nil, error_response(400, "invalid_ask", e.message)]
      end

      # A line a worker may run as a session command or a shell line, by its
      # shape (COMMAND_SHAPE): not a message.
      def command_line?(prompt)
        line = prompt.strip
        line.start_with?("!") || COMMAND_SHAPE.match?(line)
      end

      # The body's request_id: [nil or it, nil] or [nil, a 400]. A session
      # command never runs as a turn of that id (the Bridge's command path
      # takes none), so a retry would run it again: refused. Any line the
      # worker may run as one, by its shape (COMMAND_SHAPE): chi web can't
      # see a bundle's commands, which only the worker's registry has.
      def ask_request_id(body, prompt)
        request_id = body["request_id"]
        return [nil, nil] if request_id.nil?
        unless request_id.is_a?(String) && REQUEST_ID.match?(request_id)
          return [nil, error_response(400, "invalid_ask", "request_id is 1 to 128 printable ASCII characters")]
        end

        if command_line?(prompt)
          return [nil, error_response(400, "invalid_ask", "request_id is for messages, not session commands")]
        end

        [request_id, nil]
      end

      # Who asks: the owner (WEB_UNNAMED) unless the body names a sender
      # (owner_sender's rule); a parent agent's /continue yes sent as
      # cli:send or an agent's id (ClientId.parent_line?) goes in as
      # cli:answer, as chi send sends it (the worker holds that one to
      # guardrails.parent_answers).
      def ask_sender(client_id, prompt)
        sender = owner_sender({ "client_id" => client_id })
        TurnFlow.continue_yes?(prompt) ? AgentCaller.continue_id(sender) : sender
      end

      # A parent agent's line refused before anything is sent, as POST
      # …/turn refuses it (#parent_gate), held to the parent_answers of the
      # session asked and of its chain's newest link (where it goes).
      # @return [Array, nil] the response, or nil to go on
      def ask_gate(id, prompt, client_id)
        return nil unless ClientId.parent_line?(client_id)

        asked = session_access.resolve(id)
        ids = [asked, session_access.head(asked).id].uniq
        sessions = ids.select { |sid| File.file?(Session.session_file(sid, state_dir: default_state_dir)) }
        values = sessions.map { |sid| session_access.show(sid).parent_answers }
        # No session left to read: config.yml's value alone (fail closed),
        # as SendCommand::ParentGate#target_values falls back.
        values = [nil] if values.empty?
        parent_gate(prompt, client_id: client_id, values: values)
      rescue ArgumentError # degrade-ok: no such session, or a prefix of several: the ask's own answer says which
        nil
      end

      # The ask's answer for an Ask value (+request_id+ echoed when given:
      # the client sees this chi web used it), shaped for +reply_for+ (the
      # request's: a /continue yes's too, which opens no message), its token
      # carrying it for the next wait.
      def ask_response(id, outcome, request_id: nil, reply_for: nil)
        case outcome
        when SessionAccess::Ask::Ran then json_response(200, { status: "command", session_id: outcome.session_id })
        when SessionAccess::Ask::Refused then ask_refused(id, outcome, reply_for: reply_for)
        else
          result = outcome.result
          return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

          json = wait_result_json(result, session_access.parent_strategy(outcome.session_id), reply_for: reply_for)
                 .merge(session_id: outcome.session_id)
          json[:asked] = outcome.asked if outcome.asked && outcome.asked != outcome.session_id
          json[:token] = SessionAccess::Exchange::Token.carrying(outcome.token, reply_for) if outcome.token
          json[:request_id] = request_id if request_id
          json_response(200, json)
        end
      end

      # Neutral words for a Busy, not chi send's flags.
      ASK_BUSY_WORDS = { "busy" => "a turn is running: ask with queue, or wait for it",
                         "waiting" => "a question waits for an answer" }.freeze

      def ask_refused(id, refused, reply_for: nil)
        case refused.kind
        when :canceled then error_response(503, "server_stopping", "chi web is stopping; ask again")
        when :unknown
          error = refused.error
          return refusal_response(400, "ambiguous_id", error, ids: error.ids) if error.is_a?(Session::AmbiguousId)

          session_not_found(id)
        when :continuing then refusal(409, "continuing", refused.message, session_id: refused.session_id)
        when :busy
          words = ASK_BUSY_WORDS.fetch(refused.busy.error)
          json = busy_json(refused.busy).merge(detail: words, message: words)
          json_response(409, json.merge(needs_detail_fields(reply_for, refused.busy.question)))
        else refused_delivery(refused.result)
        end
      end

      # POST /api/sessions/:id/wait {token, timeout}: the wait a token holds
      # (an ask's, a create's, an answer's), for at most WAIT_MAX_SECONDS.
      # The URL's id may be a prefix. 200 wait_result_json's fields +
      # session_id (+ token, the same, while the status is timeout); 400 invalid_wait for a token that isn't one,
      # another session's, a token beside the wait's own fields, or a
      # participant's; 503 server_stopping.
      def handle_token_wait(req, id, body)
        return error_response(400, "invalid_wait", "a participant's wait takes a turn, not a token") unless principal(req).owner?
        if TOKEN_EXCLUDES.any? { |key| ![nil, false].include?(body[key]) }
          return error_response(400, "invalid_wait", "token or the wait's fields, not both")
        end

        timeout = body["timeout"]
        unless timeout.nil? || (timeout.is_a?(Numeric) && timeout.positive?)
          return error_response(400, "invalid_wait", "timeout is positive seconds")
        end

        session_id, target = SessionAccess::Exchange::Token.load(body["token"])
        reply_for = SessionAccess::Exchange::Token.reply_for(body["token"])
        # The URL's id may be a prefix (as the ask's): resolved first (no
        # such session, or several: session_route's 404).
        full = session_access.resolve(id)
        return error_response(400, "invalid_wait", "the token is another session's wait") unless session_id == full

        result = plain_exchange.wait(full, target, timeout: [timeout || WAIT_MAX_SECONDS, WAIT_MAX_SECONDS].min,
                                                   **wait_extras)
        return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

        json = wait_result_json(result, session_access.parent_strategy(full), reply_for: reply_for).merge(session_id: full)
        json[:token] = body["token"] if result.status == :timeout
        json_response(200, json)
      rescue SessionAccess::Exchange::Token::Invalid => e
        error_response(400, "invalid_wait", e.message)
      end

      # The answer's wait: [seconds, nil] (nil seconds: none asked), or
      # [nil, a 400 response].
      def answer_wait_option(body)
        wait = body["wait"]
        return [nil, nil] if wait.nil? || wait == false
        return [nil, error_response(400, "invalid_wait", "wait is positive seconds")] unless wait.is_a?(Numeric) && wait.positive?

        [[wait, WAIT_MAX_SECONDS].min, nil]
      end

      # What an answer's wait reads before the answer goes in
      # (AnswerCommand's): the answered question is not the next thing.
      # @return [WaitStart, nil] nil: the session is gone
      def answer_wait_start(id, session, question_id)
        session_access.prepare_wait(id, session: session, question_id: question_id.to_s)
      rescue ArgumentError # degrade-ok: deleted meanwhile, the answer's 404
        nil
      end

      # POST …/answer with wait: the answer relayed (+answered+; false: the
      # question was answered elsewhere first, as chi answer still waits)
      # and what comes next, for up to +seconds+. 200 {status: answered |
      # not_pending, (answered_here: false,) session_id, id, reply:
      # {wait_result_json's fields, token while it is timeout}}. The answer
      # went in before the wait, so a wait that fails (chi web stopping, the
      # session deleted, its files unreadable) is still a 200: wait_error
      # {error: server_stopping | not_found | wait_failed, detail} in place
      # of reply (an answer retried would be 409). +reply_for+: the pending
      # turn's (its saved opener's, read before the answer went in), which
      # shapes the reply and rides its token.
      def answered_wait(id, question_id, start, seconds, answered:, reply_for: nil)
        head = answered ? { status: "answered" } : { status: "not_pending", answered_here: false }
        head = { **head, session_id: id, id: question_id }
        target = ReplyWait::Target.answer(start)
        result = plain_exchange.wait(id, target, timeout: seconds, **wait_extras)
        if result.status == :canceled
          return answer_wait_error(head, "server_stopping", "chi web is stopping; the answer went in")
        end

        reply = wait_result_json(result, session_access.parent_strategy(id), reply_for: reply_for)
        reply[:token] = SessionAccess::Exchange::Token.dump(id, target, reply_for: reply_for) if result.status == :timeout
        json_response(200, { **head, reply: reply })
      rescue ArgumentError => e # deleted while waiting
        answer_wait_error(head, "not_found", e.message)
      rescue SystemCallError, IOError => e
        answer_wait_error(head, "wait_failed", "#{e.class}: #{e.message}")
      end

      def answer_wait_error(head, error, detail) = json_response(200, { **head, wait_error: { error: error, detail: detail } })

      # A create's 201 token, for a session started with its first turn
      # (first_turn_id): POST …/wait {token} answers that turn. {} for an
      # idle one.
      def create_token(session)
        turn = session.first_turn_id.to_s
        return {} if turn.empty?

        start = session_access.prepare_wait(session.id, session: (session if session.is_a?(Session)), created: true)
        target = ReplyWait::Target.first_message(start, nil, direct_turn: turn)
        { token: SessionAccess::Exchange::Token.dump(session.id, target) }
      end

      def plain_exchange = SessionAccess::Exchange.new(session_access)

      # The worker's Bridge client for an ask's delivery (App's
      # live_bridge_client, drawn from +deadline+): a worker starting is
      # waited for out of what is left, and the post's read is what is left
      # after that but MIN_SLICE, within POST_FLOOR..READ_TIMEOUT. The
      # client's body deadline is a share of that read (DEADLINE_SHARE, at
      # least POST_MARGIN short of it), so
      # a worker that reads the message late drops it (408
      # deadline_passed) rather than run it after the call gave up.
      # @param deadline [Numeric] ask_clock's seconds the call ends by
      # @return [BridgeClient, nil] nil: no live worker in time
      def ask_bridge(sid, deadline)
        link = worker_link(sid)
        link = await_worker_link(sid, timeout: [@bridge_wait_timeout.to_f, deadline - ask_clock].min.clamp(0.0..)) unless link.live?
        return nil unless link.live?

        read = (deadline - ask_clock - SessionAccess::Ask::MIN_SLICE).clamp(POST_FLOOR, BridgeClient::READ_TIMEOUT)
        link.client(sid, host: App::DEFAULT_HOST, read_timeout: read, deadline_margin: POST_MARGIN)
      end

      # The ask's deadline clock (the Exchange's: monotonic seconds).
      def ask_clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def wait_extras = { poll_interval: @wait_poll_interval, cancelled: -> { !@server_running.call } }.compact
    end
  end
end
