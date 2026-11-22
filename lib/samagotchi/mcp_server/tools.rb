# frozen_string_literal: true

require_relative "../agent_caller"
require_relative "../client_id"
require_relative "../session_inbox"
require_relative "../turn_flow"
require_relative "../session_access/ask"
require_relative "../session_access/exchange"
require_relative "../session_access/exchange/token"
require_relative "text"

module Samagotchi
  module McpServer
    # The four tools an MCP host's model sees (chi_sessions, chi_ask,
    # chi_wait, chi_answer): their definitions (#list) and their calls
    # (#call). The only file of the server that names SessionAccess: it
    # reaches sessions through the +access+ it is given (Local, Remote or
    # chi web's per-request wrapper) and SessionAccess::Ask / Exchange,
    # built per call (they keep no state). The caller is a parent agent:
    # its turns go in as chi send's, its answers and its /continue yes as
    # chi answer's, so guardrails.parent_answers holds it.
    class Tools
      # Seconds one call waits before it answers "still running" (spike D2:
      # well inside Claude Code HTTP's 60 s and Codex's 300 s).
      SLICE = 25
      # The agent an MCP host's messages go as when nothing names it.
      DEFAULT_AGENT = "mcp"
      # The most seconds a chi_ask or a chi_answer takes in all
      # (Web::AskRoutes::ASK_MAX_SECONDS); under --remote about a minute for
      # a slow worker (the other chi web's routes make their own tries).
      CAP = 35
      LIST_LIMIT = 20
      LIST_MAX = 50

      # Bad arguments: the message is the tool's error text.
      class BadArguments < StandardError; end

      DEFINITIONS = [
        { name: "chi_sessions",
          description: "List chi sessions, newest first: id, title, status, whether a question waits, project.",
          inputSchema: { type: "object", additionalProperties: false,
                         properties: { dir: { type: "string", description: "only sessions in this folder or below" },
                                       live: { type: "boolean", description: "only sessions a worker runs now" },
                                       limit: { type: "integer", minimum: 1, maximum: LIST_MAX,
                                                description: "at most this many (default #{LIST_LIMIT})" } } },
          annotations: { readOnlyHint: true } },
        { name: "chi_ask",
          description: "Send a message to a chi session as its own turn and wait for the answer. A result that is " \
                       "still running carries a token for chi_wait; one with a question waiting is answered with " \
                       "chi_answer.",
          inputSchema: { type: "object", additionalProperties: false, required: %w[session prompt],
                         properties: { session: { type: "string", description: "the session's id or an id prefix" },
                                       prompt: { type: "string", description: "the message for the session's model" } } },
          annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false } },
        { name: "chi_wait",
          description: "Keep waiting for a chi turn that was still running, by the token its result carried.",
          inputSchema: { type: "object", additionalProperties: false, required: %w[token],
                         properties: { token: { type: "string", description: "the token of a still-running result" } } },
          annotations: { readOnlyHint: false, idempotentHint: false } },
        { name: "chi_answer",
          description: "Answer the question a chi session waits on (by its question_id), then wait for what comes next.",
          inputSchema: { type: "object", additionalProperties: false, required: %w[session question_id],
                         properties: {
                           session: { type: "string", description: "the session's id" },
                           question_id: { type: "string", description: "the question's id, from the result" },
                           option: { type: %w[string integer], description: "one option: its label or its number (1-based)" },
                           options: { type: "array", items: { type: %w[string integer] },
                                      description: "several options, on a question that takes several" },
                           text: { type: "string", description: "free text, where the question takes it" }
                         } },
          annotations: { readOnlyHint: false, idempotentHint: false } }
      ].freeze

      # @param access [SessionAccess::Local, SessionAccess::Remote, #answer]
      # @param slice [Numeric] seconds a call waits (SLICE)
      # @param cap [Numeric] seconds a chi_ask or chi_answer takes in all (CAP)
      # @param exchange [#call, nil] (access) -> the Exchange a call uses
      #   (chi web's carries its stop check); nil: a plain one
      # @param agent [String] the name its messages go as (agent:<name>):
      #   the host's marker on stdio (McpCommand), "mcp" over HTTP
      def initialize(access, slice: SLICE, cap: CAP, exchange: nil, cancelled: nil, agent: DEFAULT_AGENT)
        @access = access
        @agent = agent
        @slice = slice
        @cap = cap
        @exchange = exchange || ->(backend) { SessionAccess::Exchange.new(backend) }
        @cancelled = cancelled
      end

      def list = DEFINITIONS

      # @return [Hash] a tools/call result; never raises (a call must
      #   always answer, or the host hangs to its own timeout)
      def call(name, arguments)
        case name
        when "chi_sessions" then sessions(arguments)
        when "chi_ask" then ask(arguments)
        when "chi_wait" then wait(arguments)
        when "chi_answer" then answer(arguments)
        else raise ArgumentError, "no tool #{name}"
        end
      rescue BadArguments, SessionInbox::NoteRejected, SessionAccess::Exchange::Token::Invalid => e
        Text.error(e.message)
      rescue StandardError => e
        Text.error(e.message.to_s.empty? ? e.class.name : e.message)
      end

      private

      def sessions(arguments)
        dir = optional(arguments, "dir", String)
        live = optional(arguments, "live", [true, false])
        limit = optional(arguments, "limit", Integer) || LIST_LIMIT
        raise BadArguments, "limit is 1 to #{LIST_MAX}" unless limit.between?(1, LIST_MAX)

        filters = { live: live == true, limit: limit }
        filters[:cwd] = File.expand_path(dir) if dir && !@access.remote?
        filters[:cwd] = dir if dir && @access.remote?
        Text.sessions(@access.summaries(**filters).first(limit))
      end

      def ask(arguments)
        given = required(arguments, "session")
        prompt = SessionInbox.checked_text(required(arguments, "prompt"), noun: "message")
        return Text.error(Text::COMMAND_REFUSED, reason: "command") if command_line?(prompt)

        asker = SessionAccess::Ask.new(@access, exchange: exchange)
        client_id = sender(asker, given, prompt)
        return Text.refused(client_id) if client_id.is_a?(SessionAccess::Ask::Refused)

        more = @cancelled ? { cancelled: @cancelled } : {}
        outcome = asker.call(given, prompt: prompt, client_id: client_id, queue: true, timeout: @slice, cap: @cap, **more)
        outcome(outcome)
      end

      def wait(arguments)
        id, target = SessionAccess::Exchange::Token.load(required(arguments, "token"))
        more = @cancelled ? { cancelled: @cancelled } : {}
        result = exchange.wait(id, target, timeout: @slice, **more)
        token = SessionAccess::Exchange::Token.dump(id, target) if result.status == :timeout
        Text.wait_result(result, session_id: id, token: token, strategy: @access.parent_strategy(id))
      end

      def answer(arguments)
        id = @access.resolve(required(arguments, "session"))
        qid = required(arguments, "question_id")
        text = optional(arguments, "text", String)
        picks = picks(arguments)
        raise BadArguments, "nothing to answer with: give option, options or text" if picks.empty? && text.nil?

        pending = @access.show(id).pending_question
        selected = pending && pending.id.to_s == qid ? selection(pending, picks) : []
        more = @cancelled ? { cancelled: @cancelled } : {}
        outcome(SessionAccess::Ask.new(@access, exchange: exchange)
                                  .answer(id, question_id: qid, selected: selected, freeform: text,
                                              client_id: ClientId::CLI_ANSWER, timeout: @slice, cap: @cap, **more),
                question_id: qid)
      end

      # @param question_id [String, nil] chi_answer's: an answer that
      #   didn't go in says so in the text, not only in answered_here
      def outcome(outcome, question_id: nil)
        case outcome
        when SessionAccess::Ask::Refused then Text.refused(outcome)
        when SessionAccess::Ask::Ran then Text.ran(outcome.session_id)
        else
          extra = outcome.answered_here ? {} : { answered_here: false }
          result = Text.wait_result(outcome.result, session_id: outcome.session_id, token: outcome.token,
                                                    strategy: @access.parent_strategy(outcome.session_id), extra: extra)
          outcome.answered_here ? result : Text.not_answered(result, question_id)
        end
      end

      # Who sends +prompt+ (Ask#agent_line): on this machine held to the
      # parent_answers of the session asked and its chain's newest link; on
      # a remote chi web's turn route gates the same ids itself.
      def sender(asker, given, prompt)
        return TurnFlow.continue_yes?(prompt) ? ClientId::CLI_ANSWER : AgentCaller.send_id(name: @agent) if @access.remote?

        asker.agent_line(prompt, session: targets(given), name: @agent)
      end

      def targets(given)
        asked = @access.resolve(given)
        [asked, @access.head(asked).id].uniq.filter_map do |id|
          @access.show(id)
        rescue ArgumentError # degrade-ok: the head not saved yet; the asked session's value still holds
          nil
        end
      rescue ArgumentError # degrade-ok: no such session: the ask's own answer says so
        []
      end

      # A shell line (!…) or a session command other than /continue.
      def command_line?(prompt)
        line = prompt.lstrip
        return true if line.start_with?("!")

        line.start_with?("/") && !line.match?(%r{\A/continue(\s|\z)})
      end

      # option / options as given (labels or 1-based numbers).
      def picks(arguments)
        one = arguments["option"]
        many = arguments["options"]
        raise BadArguments, "option is a label or a number" unless one.nil? || one.is_a?(String) || one.is_a?(Integer)
        unless many.nil? || (many.is_a?(Array) && many.all? { |pick| pick.is_a?(String) || pick.is_a?(Integer) })
          raise BadArguments, "options is a list of labels or numbers"
        end

        [*one, *many].map(&:to_s)
      end

      # The labels to send, as chi answer resolves them: an exact label
      # wins over a number; several only on a multi-select question.
      def selection(pending, picks)
        offered = Array(pending.options).map(&:to_s)
        labels = picks.map do |given|
          next given if offered.include?(given)

          index = Integer(given, exception: false)
          next offered[index - 1] if index&.between?(1, offered.size)

          listed = offered.each_with_index.map { |label, i| "#{i + 1}. #{label}" }.join(", ")
          raise BadArguments, "no option #{given}; the options: #{listed}"
        end
        raise BadArguments, "one option only: the question is single-select" if labels.uniq.size > 1 && !pending.multi_select

        labels.uniq
      end

      def exchange = @exchange.call(@access)

      def required(arguments, key)
        value = arguments[key]
        raise BadArguments, "#{key} is required (a string)" unless value.is_a?(String) && !value.strip.empty?

        value
      end

      def optional(arguments, key, kind)
        value = arguments[key]
        return nil if value.nil?

        ok = kind.is_a?(Array) ? kind.include?(value) : value.is_a?(kind)
        raise BadArguments, "#{key} has the wrong type" unless ok

        value
      end
    end
  end
end
