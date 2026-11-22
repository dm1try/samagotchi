# frozen_string_literal: true

require_relative "exchange"
require_relative "exchange/token"
require_relative "../bridge_client"
require_relative "../bridge_secret"
require_relative "../agent_caller"
require_relative "../client_id"
require_relative "../parent_answers_command"
require_relative "../reply_wait/target"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../turn_flow"
require_relative "../send_command/parent_gate"

module Samagotchi
  module SessionAccess
    # One message in, its answer out, for a thin client (chi web's POST
    # …/ask, plan 2's MCP server): the session located (a chain's newest
    # link, a continue in flight waited for), a running turn's busy check,
    # the wait's start read before the message goes in, the delivery (a
    # continue that took the link meanwhile: located again and sent there),
    # then one slice of the wait. Everything draws on one deadline (+cap+),
    # so the call answers in time for a proxy or a Shortcut; a turn still
    # running then is a Reply with status :timeout and a wait token
    # (Exchange::Token). The waits for a continue end MIN_SLICE before the
    # deadline, so the slice fits; a delivery's own time counts (a slow one
    # leaves a shorter slice, and one past the deadline gets no second
    # delivery). One per call, no state kept after it. It answers
    # values, never an HTTP shape; the backend's errors raise
    # (SessionManager::OwnedByTUI, ArgumentError for a session deleted
    # meanwhile).
    class Ask
      # The answer of a delivered message: +session_id+ where it ran (the
      # chain's newest link), +asked+ the full id given, +result+ the
      # ReplyWait::Result, +token+ for a :timeout (the next wait's).
      # #answer's: +answered_here+ false when the question was no longer
      # open (answered elsewhere first, or a newer one waits): what came
      # next is still waited for, as chi answer does. +rebound+: a request_id
      # whose turn was already known, so nothing was sent this time (the
      # first ask's turn waited on again).
      Reply = Data.define(:session_id, :asked, :result, :token, :answered_here, :rebound) do
        def initialize(session_id:, asked:, result:, token:, answered_here: true, rebound: false) = super
      end

      # The line ran as a session command (/model x): no reply comes. A
      # /continue yes with an offer standing (an idle session's continue
      # question, its worker running) is a Reply instead: it waits on the
      # continued turn (#continue_follows?).
      Ran = Data.define(:session_id)

      # Nothing went in. +kind+ :unknown (+error+ the resolve's
      # ArgumentError), :continuing (a continue in flight past the wait,
      # +message+ its refusal), :busy (+busy+ the SendCommand::Busy: a turn
      # runs and queue was false, or a question waits) or :undelivered
      # (+result+ the refused DeliverResult) or :canceled (+cancelled+ turned
      # true before anything was sent: chi web stopping). #agent_line's
      # :parent_refused (+message+ why). #answer's (+message+ each):
      # :no_question (none of that id waits and nothing runs), :not_live (no
      # worker runs it), :bridge_secret, :not_dismissable, :invalid_answer
      # (the Bridge refused the selection), :parent_refused (the worker's
      # parent_answers), :late (the worker didn't take it in time),
      # :stale_worker (an older worker without the answer route), :failed.
      Refused = Data.define(:kind, :session_id, :busy, :result, :error, :message) do
        def initialize(kind:, session_id: nil, busy: nil, result: nil, error: nil, message: nil) = super
      end

      # The shortest wait slice, however little of the cap is left.
      MIN_SLICE = 1.0

      # @param access [SessionAccess::Local, #deliver_turn] the backend (chi
      #   web's wraps Local to deliver through its own manager and Bridge)
      # @param exchange [Exchange] over the same backend
      # @param clock [#call] monotonic seconds (the exchange's own by default)
      def initialize(access, exchange:, clock: nil)
        @access = access
        @exchange = exchange
        @clock = clock || -> { exchange.now }
      end

      # @param given [String] an id or a prefix
      # @param client_id [String] who sends it (ClientId)
      # @param queue [Boolean] a running session queues it as its own turn;
      #   false refuses one (:busy)
      # @param timeout [Numeric] the most seconds for the wait's slice
      # @param cap [Numeric] the most seconds for the whole call
      # @param continuing_wait [Numeric] the most seconds a continue that
      #   took the link is waited for (Exchange::CONTINUING_WAIT)
      # @param cancelled [#call, nil] true stops the wait (status :canceled);
      #   before the delivery, the call (Refused :canceled). The exchange's
      #   own cancelled: (the same) cuts its waits for a continue
      # @param request_id [String, nil] the client's key for this ask (a
      #   message, never a command): its turn's enqueued id is
      #   SessionInbox.enqueued_id_for("ask:" + it). A turn of that id the
      #   session knows (running, queued, ended: ReplyWait.known_turn?) is
      #   waited on again, nothing sent (Reply rebound), unless it only waits
      #   as an input file with no worker running (#waiting_turn?); else the
      #   delivery carries the id, which the Bridge dedupes
      # @param anchors [TurnAnchors, Hash, nil] what the turn points at
      #   (TurnAnchors), on every delivery (each relocation after a
      #   continue's too); nil: none sent, as before
      # @return [Reply, Ran, Refused]
      def call(given, prompt:, client_id:, queue:, timeout:, cap:, continuing_wait: Exchange::CONTINUING_WAIT,
               cancelled: nil, request_id: nil, anchors: nil)
        enqueued_id = SessionInbox.enqueued_id_for("ask:#{request_id}") if request_id
        deadline = @clock.call + cap
        # Everything before the wait ends by here, so its MIN_SLICE fits.
        ready_by = deadline - MIN_SLICE
        found = @exchange.locate(given, deadline: ready_by)
        at = found.target if found.is_a?(Exchange::Located)
        return Refused.new(kind: :canceled, session_id: at&.id || found.asked) if cancelled&.call
        return unsent(found, nil) if found.is_a?(Exchange::Unsent)

        follow_until = nil
        loop do
          return Refused.new(kind: :canceled, session_id: at.id) if cancelled&.call

          session = @access.show(at.id)
          start = (@access.prepare_wait(at.id, session: session, turn: enqueued_id) if enqueued_id)
          # A turn known only as an input file no worker reads is sent again
          # (with E: the worker runs it once), so the delivery wakes one.
          if start&.known_turn && (start.live || !@access.waiting_turn?(at.id, enqueued_id))
            # chi send --wait --turn E's binding, queued as the first copy was
            # sent (a queue never merges: no merge fallback onto another turn).
            target = ReplyWait::Target.wait_only(start, requested: enqueued_id).with(queued: queue)
            return wait(at, target, slice: slice(timeout, deadline), cancelled: cancelled, rebound: true)
          end

          busy = @access.busy(at.id, queue: queue, session: session)
          return Refused.new(kind: :busy, session_id: at.id, busy: busy) if busy

          start ||= @access.prepare_wait(at.id, session: session)
          more = { enqueued_id: enqueued_id, anchors: anchors }.compact
          result = @exchange.attempt(at, prompt, client_id: client_id, queue: queue, **more).result
          if result.continued?
            follow_until ||= [@clock.call + continuing_wait, ready_by].min
            again = @exchange.relocate(at, follow_until, bounded: true)
            return Refused.new(kind: :canceled, session_id: at.id) if cancelled&.call
            return Refused.new(kind: :continuing, session_id: at.id, message: result.refusal_text) unless again
            return unsent(again, at.id) if again.is_a?(Exchange::Unsent)

            at = again.target
            next
          end
          return Refused.new(kind: :undelivered, session_id: at.id, result: result) unless result.accepted?

          if result.command?
            return Ran.new(session_id: at.id) unless continue_follows?(prompt, start)

            # The continue turn runs under the offered turn's id (own_turn),
            # as chi answer follows it: the worker's ack is not read.
            return wait(at, ReplyWait::Target.answer(start), slice: slice(timeout, deadline), cancelled: cancelled)
          end

          target = @exchange.bind(start, result, queue: queue)
          return wait(at, target, slice: slice(timeout, deadline), cancelled: cancelled)
        end
      end

      # What a parent agent's line (an MCP host's, chi send's over HTTP) is
      # held to, with no read of this process (an ENV marker, a tty): a
      # /continue yes always goes in as chi answer's (the worker holds it
      # to guardrails.parent_answers only then), anything else as chi
      # send's; refused first when the parent policy refuses that continue,
      # or when it is a /parent-answers line loosening a target's own value
      # (Web::SessionCreate#parent_gate's two checks, for those ids).
      # @param session [Session, Array<Session>, nil] the targets (the
      #   session asked and its chain's newest link); none: config.yml's
      #   value alone (fail closed)
      # @return [String, Refused] the client_id to send as, or why not
      # @param name [String, nil] the agent's name (AgentCaller): its line
      #   goes as agent:<name>; nil: chi send's
      def agent_line(prompt, session:, name: nil)
        sessions = Array(session).compact
        values = sessions.empty? ? [nil] : sessions.map(&:parent_answers)
        continue = TurnFlow.continue_yes?(prompt)
        refusal = SendCommand::ParentGate.continue_refusal_for(values) if continue
        refusal ||= ParentAnswersCommand::REFUSED if SendCommand::ParentGate.loosens_any?(prompt, values)
        return Refused.new(kind: :parent_refused, session_id: sessions.first&.id, message: refusal) if refusal

        continue ? ClientId::CLI_ANSWER : AgentCaller.send_id(name: name)
      end

      # The answer to the question session +id+ waits on, then one slice of
      # the wait for what comes next (AnswerCommand's sequence, as values):
      # a question no longer open is not answered but still waited past
      # (Reply answered_here: false) while the session runs.
      # @param id [String] the session's full id
      # @param selected [Array<String>] the option labels
      # @param freeform [String, nil]
      # @param timeout [Numeric] the wait's slice
      # @param cap [Numeric, nil] the most seconds for the whole call (an
      #   MCP host's limit): the post gets what is left but MIN_SLICE, the
      #   wait the rest (#slice); nil: the post's own limits, then +timeout+
      # @return [Reply, Refused]
      def answer(id, question_id:, selected:, freeform:, client_id:, timeout:, cap: nil, cancelled: nil)
        deadline = @clock.call + cap if cap
        qid = question_id.to_s
        session = @access.show(id)
        pending = session.pending_question
        open = pending && pending.id.to_s == qid
        if !open && session.status != Session::STATUS_RUNNING
          return Refused.new(kind: :no_question, session_id: id, message: "no question #{qid} waits in #{id[0, 8]}; nothing to answer")
        end

        start = @access.prepare_wait(id, session: session, question_id: qid)
        answered_here = false
        if open
          within = (deadline - MIN_SLICE - @clock.call).clamp(MIN_SLICE..) if deadline
          posted = post_answer(id, qid, selected, freeform, client_id, within)
          return posted if posted.is_a?(Refused)

          answered_here = posted
        end
        target = ReplyWait::Target.answer(start)
        more = cancelled ? { cancelled: cancelled } : {}
        result = @exchange.wait(id, target, timeout: deadline ? slice(timeout, deadline) : timeout, **more)
        token = Exchange::Token.dump(id, target) if result.status == :timeout
        Reply.new(session_id: id, asked: id, result: result, token: token, answered_here: answered_here)
      end

      # The words for an answer the worker didn't take in time
      # (AnswerCommand's own, copied).
      LATE_WORDS = "the worker did not take the answer in time; the question is still open: try again"

      private

      # The answer posted, its reply read as AnswerCommand#post reads it.
      # @return [Boolean, Refused] true answered, false no longer open (409)
      def post_answer(id, qid, selected, freeform, client_id, within)
        more = within ? { within: within } : {}
        reply = @access.answer(id, question_id: qid, selected: selected, freeform: freeform, client_id: client_id, **more)
        return not_live(id) unless reply
        return answer_refused(:bridge_secret, id, BridgeSecret.refused(id, via: @access.invocation)) if reply.secret_refused?

        detail = reply.json&.dig("detail")
        case reply.status
        when 200 then true
        when 409
          return answer_refused(:not_dismissable, id, detail.to_s) if reply.json&.dig("error") == "not_dismissable"

          false
        when 400 then answer_refused(:invalid_answer, id, detail || "the worker refused the answer")
        when 403 then answer_refused(:parent_refused, id, detail || "the worker refused that option: deny it, and tell your user")
        when 408 then answer_refused(:late, id, LATE_WORDS)
        when 404
          return not_live(id) if reply.json&.dig("error") == "unknown_session"

          answer_refused(:stale_worker, id, BridgeClient.stale_worker_message(id, cant: "take an answer", via: @access.invocation))
        else answer_refused(:failed, id, "the worker answered #{reply.status}: #{detail || reply.body}")
        end
      rescue Errno::ETIMEDOUT
        answer_refused(:late, id, LATE_WORDS)
      rescue SystemCallError, IOError, SocketError => e
        answer_refused(:failed, id, "#{e.class}: #{e.message}")
      end

      def not_live(id) = answer_refused(:not_live, id, "no worker runs session #{id[0, 8]}: the question went with it; send the task again")

      def answer_refused(kind, id, message) = Refused.new(kind: kind, session_id: id, message: message)

      # A /continue yes the worker ran as a command, on a session idle with
      # its continue offer standing (start's own_turn, ReplyWait.own_turn)
      # and a worker running it: the offer lives only in that worker's
      # memory, so with none (a new one says nothing to continue) a wait
      # would hand out tokens with no end.
      def continue_follows?(prompt, start)
        TurnFlow.continue_yes?(prompt) && !start.running && start.live && !start.own_turn.to_s.empty?
      end

      def wait(at, target, slice:, cancelled:, rebound: false)
        more = cancelled ? { cancelled: cancelled } : {}
        result = @exchange.wait(at.id, target, timeout: slice, **more)
        token = Exchange::Token.dump(at.id, target) if result.status == :timeout
        Reply.new(session_id: at.id, asked: at.asked, result: result, token: token, rebound: rebound)
      end

      # The wait's slice: +timeout+, cut to the time the cap leaves, never
      # under MIN_SLICE.
      def slice(timeout, deadline) = [timeout, deadline - @clock.call].min.clamp(MIN_SLICE..)

      def unsent(found, session_id)
        if found.reason == :continuing
          Refused.new(kind: :continuing, session_id: session_id || found.asked, message: found.message)
        else
          Refused.new(kind: :unknown, session_id: session_id, error: found.error, message: found.message)
        end
      end
    end
  end
end
