# frozen_string_literal: true

require "delegate"
require "digest"
require_relative "../tool_names"
require_relative "peers"

module Samagotchi
  module Tools
    # Ask another chi session a question and get its answer as the result:
    # the question goes in as that session's own turn (queued behind a
    # running one), from session:<this id8>, a visitor's turn there
    # (Visitor: one header line, counted toward its session.max_wakes). One
    # call waits up to CAP seconds (SessionAccess::Ask, as chi_ask does); a
    # turn still running then gives a token, which the next call (token:)
    # waits on. It never answers a question that session asks its user: the
    # asker has no answer tool, so it says so and its model tells its user.
    class AskSession
      NAME = ToolNames::AskSession::NAME
      # The wait's slice and the whole call's cap: chi_ask's (McpServer::Tools).
      SLICE = 25
      CAP = 35
      WAITS_ON_QUESTION = "waits on a question for its user: not answered. Tell your user; it waits in chi web " \
                          "(or chi --attach ID)"

      # A wrapped Exchange whose deliveries never go to the asker: a
      # continue that moves the target onto this session (Ask relocates the
      # head) is refused, nothing sent.
      class NotSelf < SimpleDelegator
        def initialize(exchange, asker)
          super(exchange)
          @asker = asker
        end

        def attempt(target, prompt, **)
          return __getobj__.attempt(target, prompt, **) unless target.id == @asker

          refused = SessionManager::DeliverResult.new(
            status: :refused, ack: { "error" => "self", "detail" => "#{target.id[0, 8]} is this session now (continued into it)" }
          )
          SessionAccess::Exchange::Attempted.new(target: target, session: nil, owner: nil, running: false, delivery: nil,
                                                 refs: [], result: refused)
        end
      end

      def self.name = NAME

      # @param question [String] the question (up to 16 KiB)
      # @param session [String, nil] the session asked: an id or a prefix
      # @param token [String, nil] a running answer's token, to wait on it
      # @param peers [Peers, nil]
      # @return [String]
      def self.call(question, session: nil, token: nil, peers: nil, access: nil, slice: SLICE, cap: CAP)
        return "Error: this session's id is not known here" unless peers&.session_id

        load_backend
        access ||= SessionAccess::Local.new(state_dir: peers.state_dir)
        new(peers, access, slice: slice, cap: cap)
          .run(question, session: session, token: token)
      end

      # Loaded on the first call, not with the tools: the backend (Local
      # brings chi web's probes) is too big a load for the core's start and
      # the bundle test kit's budget (core_without_web_spec, sandbox_spec).
      def self.load_backend
        require_relative "../client_id"
        require_relative "../parent_report"
        require_relative "../session"
        require_relative "../session_inbox"
        require_relative "../session_manager"
        require_relative "../session_access/local"
        require_relative "../session_access/ask"
        require_relative "../session_access/exchange"
        require_relative "../session_access/exchange/token"
        require_relative "../reply_wait"
        require_relative "../turn_checkpoint"
      end

      def initialize(peers, access, slice:, cap:)
        @peers = peers
        @access = access
        @slice = slice
        @cap = cap
        @cancelled = -> { peers.cancelled? }
      end

      def run(question, session:, token:)
        return wait(token) unless token.to_s.strip.empty?
        return "Error: give the session to ask (list_sessions shows them), or the token of a running answer" if session.to_s.strip.empty?

        ask(session.to_s.strip, SessionInbox.checked_text(question, noun: "question"))
      rescue SessionInbox::NoteRejected, SessionAccess::Exchange::Token::Invalid => e
        "Error: #{e.message}"
      rescue SessionManager::ScratchSession => e
        "Error: #{e.message}"
      rescue SessionManager::OwnedByTUI
        "Error: a one-turn chi run holds that session now; it can't take a question"
      rescue Session::NotFound => e
        "Error: #{e.message} (list_sessions shows them)"
      rescue ArgumentError => e # AmbiguousId, a file that won't load
        "Error: #{e.message}"
      end

      private

      def ask(given, question)
        if (refused = refused_before(given, question))
          return refused
        end

        head = SessionInbox::Head.resolve(:send, Session.resolve!(given, state_dir: @peers.state_dir), state_dir: @peers.state_dir)
        asker = SessionAccess::Ask.new(@access, exchange: exchange)
        reply = asker.call(given, prompt: question, client_id: ClientId.session(@peers.session_id), queue: true,
                                  timeout: @slice, cap: @cap, cancelled: @cancelled,
                                  request_id: request_id(given, question, head.id))
        words(reply)
      end

      # The two checks send_note makes (itself, a link continued into it),
      # and a line a session would run as a command (a /word a session
      # command, a ! line refused there anyway).
      def refused_before(given, question)
        id = Session.resolve!(given, state_dir: @peers.state_dir)
        Session.load(id, state_dir: @peers.state_dir)
        return "Error: #{id[0, 8]} is this session; ask_session is for other sessions" if id == @peers.session_id

        head = SessionInbox::Head.resolve(:send, id, state_dir: @peers.state_dir)
        return "Error: #{id[0, 8]} was continued into this session; ask_session is for other sessions" if head.id == @peers.session_id
        return "Error: a question can't start with ! or /: ask it in words" if question.start_with?("!", "/")

        nil
      end

      def wait(token)
        id, target = SessionAccess::Exchange::Token.load(token.to_s.strip)
        return "Error: that token is this session's; ask_session waits on other sessions" if id == @peers.session_id

        result = exchange.wait(id, target, timeout: @slice, cancelled: @cancelled)
        next_token = SessionAccess::Exchange::Token.dump(id, target) if result.status == :timeout
        outcome(result, id, next_token)
      end

      def exchange
        @exchange ||= NotSelf.new(SessionAccess::Exchange.new(@access, cancelled: @cancelled), @peers.session_id)
      end

      # The same question to the same session within one turn waits on the
      # first one's turn while that turn still runs or is queued (a retry
      # after a timeout asks once): the asker, its turn, the target as given
      # and the question. Once that turn has ended (answered, refused,
      # canceled: ReplyWait.ended_turn? on the session asked, +head_id+), the
      # same words ask again under the next key (-2, -3, …), never replaying
      # an old answer (Ask#call rebinds to any turn of its key it knows).
      def request_id(given, question, head_id)
        turn = @peers.respond_to?(:turn_id) ? @peers.turn_id : nil
        digest = Digest::SHA256.hexdigest([given, question].join("\0"))[0, 16]
        base = "#{@peers.session_id[0, 8]}-#{turn || "none"}-#{digest}"
        session = Session.load(head_id, state_dir: @peers.state_dir)
        dir = Session.session_dir(head_id, state_dir: @peers.state_dir)
        (1..).each do |n|
          key = n == 1 ? base : "#{base}-#{n}"
          enqueued = SessionInbox.enqueued_id_for("ask:#{key}")
          return key unless ReplyWait.ended_turn?(session, session_dir: dir, turn: enqueued)
        end
      end

      def words(reply)
        case reply
        when SessionAccess::Ask::Refused then refused(reply)
        when SessionAccess::Ask::Ran then "Error: session #{reply.session_id[0, 8]} ran it as a session command; no answer comes"
        else outcome(reply.result, reply.session_id, reply.token)
        end
      end

      def outcome(result, id, token)
        short = id.to_s[0, 8]
        case result.status
        when :done
          text = result.text.to_s
          "Session #{short} answered:\n#{text.strip.empty? ? "(an empty reply)" : text}"
        when :timeout
          "Session #{short} is still answering. Call ask_session again with token: #{token} (no session or question) " \
            "to keep waiting."
        when :waiting_for_answer then "Session #{short} #{WAITS_ON_QUESTION.sub("ID", short)}"
        when :no_reply then "Error: session #{short}: #{ParentReport.no_reply_line(result)}"
        when :worker_gone then "Error: session #{short}: its worker is gone; ask again to start a fresh one"
        when :stopped then "Error: session #{short} was stopped"
        when :canceled then "Error: the wait was stopped (this turn was canceled)"
        else "Error: session #{short}: #{result.status} #{result.text}".strip
        end
      end

      def refused(refused)
        short = refused.session_id.to_s[0, 8]
        case refused.kind
        when :busy
          return "Session #{short} #{WAITS_ON_QUESTION.sub("ID", short)}" if refused.busy&.error == "waiting"

          "Error: session #{short} is busy (#{refused.busy&.error}); ask again later"
        when :unknown then "Error: #{refused.error&.message || refused.message} (list_sessions shows them)"
        when :undelivered then "Error: session #{short}: #{refused.result.refusal_text}"
        when :canceled then "Error: the question was not asked (this turn was canceled)"
        else "Error: #{refused.message}"
        end
      end
    end
  end
end
