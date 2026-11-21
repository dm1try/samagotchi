# frozen_string_literal: true

require_relative "exchange"
require_relative "exchange/token"

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
    # (Exchange::Token). One per call, no state kept after it. It answers
    # values, never an HTTP shape; the backend's errors raise
    # (SessionManager::OwnedByTUI, ArgumentError for a session deleted
    # meanwhile).
    class Ask
      # The answer of a delivered message: +session_id+ where it ran (the
      # chain's newest link), +asked+ the full id given, +result+ the
      # ReplyWait::Result, +token+ for a :timeout (the next wait's).
      Reply = Data.define(:session_id, :asked, :result, :token)

      # The line ran as a session command (/model x): no reply comes.
      Ran = Data.define(:session_id)

      # Nothing went in. +kind+ :unknown (+error+ the resolve's
      # ArgumentError), :continuing (a continue in flight past the wait,
      # +message+ its refusal), :busy (+busy+ the SendCommand::Busy: a turn
      # runs and queue was false, or a question waits) or :undelivered
      # (+result+ the refused DeliverResult).
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
      # @param cancelled [#call, nil] true stops the wait (status :canceled)
      # @return [Reply, Ran, Refused]
      def call(given, prompt:, client_id:, queue:, timeout:, cap:, continuing_wait: Exchange::CONTINUING_WAIT,
               cancelled: nil)
        deadline = @clock.call + cap
        found = @exchange.locate(given)
        return unsent(found, nil) if found.is_a?(Exchange::Unsent)

        at = found.target
        follow_until = nil
        loop do
          session = @access.show(at.id)
          busy = @access.busy(at.id, queue: queue, session: session)
          return Refused.new(kind: :busy, session_id: at.id, busy: busy) if busy

          start = @access.prepare_wait(at.id, session: session)
          result = @exchange.attempt(at, prompt, client_id: client_id, queue: queue).result
          if result.continued?
            follow_until ||= [@clock.call + continuing_wait, deadline].min
            again = @exchange.relocate(at, follow_until)
            return Refused.new(kind: :continuing, session_id: at.id, message: result.refusal_text) unless again
            return unsent(again, at.id) if again.is_a?(Exchange::Unsent)

            at = again.target
            next
          end
          return Refused.new(kind: :undelivered, session_id: at.id, result: result) unless result.accepted?
          return Ran.new(session_id: at.id) if result.command?

          return wait(at, start, result, queue: queue, slice: slice(timeout, deadline), cancelled: cancelled)
        end
      end

      private

      def wait(at, start, delivered, queue:, slice:, cancelled:)
        target = @exchange.bind(start, delivered, queue: queue)
        more = cancelled ? { cancelled: cancelled } : {}
        result = @exchange.wait(at.id, target, timeout: slice, **more)
        token = Exchange::Token.dump(at.id, target) if result.status == :timeout
        Reply.new(session_id: at.id, asked: at.asked, result: result, token: token)
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
