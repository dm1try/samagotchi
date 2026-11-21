# frozen_string_literal: true

require "delegate"
require_relative "../client_id"
require_relative "../reply_wait"
require_relative "../session"
require_relative "../session_command_catalog"
require_relative "../session_inbox"
require_relative "../turn_flow"
require_relative "../session_access/ask"
require_relative "../session_access/exchange"
require_relative "../session_access/exchange/token"
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
      # One ask answers within this many seconds, whatever it waits for (a
      # continue in flight, the delivery, the wait's slice): a proxy or a
      # Shortcut with a 60 s limit is safe.
      ASK_MAX_SECONDS = 35.0
      # A wait route answers within this many seconds (status timeout); the
      # client asks again until its own --timeout. SessionAccessRoutes'
      # (which includes this module) too.
      WAIT_MAX_SECONDS = 30.0
      # GET /api/info's feature: this chi web has the ask route, wait
      # tokens, the answer's wait and the create's token.
      ASK_FEATURE = "ask"
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

      # POST /api/sessions/:id/ask {prompt, timeout, queue, client_id}: the
      # message delivered (to a chain's newest link; a running session
      # queues it as its own turn unless queue is false) and its answer
      # waited for, all within ASK_MAX_SECONDS. 200 wait_result_json's
      # fields + session_id (+ asked, the id given, when another link ran
      # it; + token when the status is timeout: POST …/wait {token} goes
      # on); 200 {status: command} for a session command. 404 not_found,
      # 400 ambiguous_id, 409 busy / waiting / continuing / owned_by_tui,
      # the turn route's delivery refusals, 503 server_stopping.
      def handle_ask(req, id)
        body = body_hash(req) or return error_response(400, "invalid_json", "invalid JSON body")
        prompt, client_id, options, error = ask_request(id, body)
        return error if error

        gated = ask_gate(id, prompt, client_id)
        return gated if gated

        access = AskAccess.new(session_access, manager: @manager, bridge: ->(sid) { live_bridge_client(sid) },
                                               poll_interval: @wait_poll_interval)
        exchange = SessionAccess::Exchange.new(access, continuing_wait: [SessionAccess::Exchange::CONTINUING_WAIT,
                                                                         ASK_MAX_SECONDS].min)
        outcome = SessionAccess::Ask.new(access, exchange: exchange)
                                    .call(id, prompt: prompt, client_id: client_id, cap: ASK_MAX_SECONDS,
                                              cancelled: -> { !@server_running.call }, **options)
        record_history(body, prompt) unless outcome.is_a?(SessionAccess::Ask::Refused)
        ask_response(id, outcome)
      rescue SessionManager::OwnedByTUI => e
        owned_by_tui(e)
      end

      # The ask's body read: [prompt, client_id, {queue:, timeout:}, nil] or
      # [.., a 400 response].
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

        [prompt, ask_sender(client_id, prompt), { queue: queue, timeout: [timeout, WAIT_MAX_SECONDS].min }, nil]
      rescue SessionInbox::NoteRejected => e
        [nil, nil, nil, error_response(400, "invalid_prompt", e.message)]
      end

      # Who asks: the owner (WEB_UNNAMED) unless the body names a sender
      # (owner_sender's rule); a parent agent's /continue yes sent as
      # cli:send goes in as cli:answer, as chi send sends it (the worker
      # holds that one to guardrails.parent_answers).
      def ask_sender(client_id, prompt)
        sender = owner_sender({ "client_id" => client_id })
        sender == ClientId::CLI_SEND && TurnFlow.continue_yes?(prompt) ? ClientId::CLI_ANSWER : sender
      end

      # A parent agent's line refused before anything is sent, as POST
      # …/turn refuses it (#parent_gate), held to the parent_answers of the
      # session asked and of its chain's newest link (where it goes).
      # @return [Array, nil] the response, or nil to go on
      def ask_gate(id, prompt, client_id)
        return nil unless App::CLI_SEND_IDS.include?(client_id)

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

      # The ask's answer for an Ask value.
      def ask_response(id, outcome)
        case outcome
        when SessionAccess::Ask::Ran then json_response(200, { status: "command", session_id: outcome.session_id })
        when SessionAccess::Ask::Refused then ask_refused(id, outcome)
        else
          result = outcome.result
          return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

          json = wait_result_json(result, session_access.parent_strategy(outcome.session_id)).merge(session_id: outcome.session_id)
          json[:asked] = outcome.asked if outcome.asked && outcome.asked != outcome.session_id
          json[:token] = outcome.token if outcome.token
          json_response(200, json)
        end
      end

      # Neutral words for a Busy, not chi send's flags.
      ASK_BUSY_WORDS = { "busy" => "a turn is running: ask with queue, or wait for it",
                         "waiting" => "a question waits for an answer" }.freeze

      def ask_refused(id, refused)
        case refused.kind
        when :unknown
          error = refused.error
          return refusal_response(400, "ambiguous_id", error, ids: error.ids) if error.is_a?(Session::AmbiguousId)

          session_not_found(id)
        when :continuing then refusal(409, "continuing", refused.message, session_id: refused.session_id)
        when :busy
          words = ASK_BUSY_WORDS.fetch(refused.busy.error)
          json_response(409, busy_json(refused.busy).merge(detail: words, message: words))
        else refused_delivery(refused.result)
        end
      end

      # POST /api/sessions/:id/wait {token, timeout}: the wait a token holds
      # (an ask's, a create's, an answer's), for at most WAIT_MAX_SECONDS.
      # 200 wait_result_json's fields + session_id (+ token, the same, while
      # the status is timeout); 400 invalid_wait for a token that isn't one,
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
        return error_response(400, "invalid_wait", "the token is another session's wait") unless session_id == id

        session_access.show(id)
        result = plain_exchange.wait(id, target, timeout: [timeout || WAIT_MAX_SECONDS, WAIT_MAX_SECONDS].min,
                                                 **wait_extras)
        return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

        json = wait_result_json(result, session_access.parent_strategy(id)).merge(session_id: id)
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
      # {wait_result_json's fields, token while it is timeout}}.
      def answered_wait(id, question_id, start, seconds, answered:)
        target = ReplyWait::Target.answer(start)
        result = plain_exchange.wait(id, target, timeout: seconds, **wait_extras)
        return error_response(503, "server_stopping", "chi web is stopping; wait again") if result.status == :canceled

        reply = wait_result_json(result, session_access.parent_strategy(id))
        reply[:token] = SessionAccess::Exchange::Token.dump(id, target) if result.status == :timeout
        head = answered ? { status: "answered" } : { status: "not_pending", answered_here: false }
        json_response(200, { **head, session_id: id, id: question_id, reply: reply })
      rescue ArgumentError # deleted while waiting
        session_not_found(id)
      end

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

      def wait_extras = { poll_interval: @wait_poll_interval, cancelled: -> { !@server_running.call } }.compact
    end
  end
end
