# frozen_string_literal: true

require_relative "../delivery"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../reply_wait/target"

module Samagotchi
  module SessionAccess
    # The stateless pieces of "send one message and bind its wait", over a
    # SessionAccess backend (Local or Remote: only their public methods),
    # for every front that sends: chi send (SendCommand, which keeps its
    # retry loop and its lines), chi answer's wait (CLI::ParentWait) and chi
    # web's ask (SessionAccess::Ask). It prints nothing, knows no command
    # name, keeps no state between calls (chi web builds one per request),
    # never retries, and lets the backend's errors raise; it answers values.
    # See docs/internals/remote-sessions.md (Exchange).
    class Exchange
      # How long a send to a link being continued waits for the new link to
      # be saved, and how often it asks again (SendCommand's own constants
      # have the same values, which its specs stub).
      CONTINUING_WAIT = 10.0
      CONTINUING_POLL = 0.2

      # +given+ named a session: +target+ where input for it goes (a
      # SessionInbox::Resolved), +waited+ whether a continue in flight was
      # waited for on the way.
      Located = Data.define(:target, :waited)

      # +given+ named no session to send to: +reason+ :continuing (a
      # continue of +asked+, the full id, still in flight past the wait;
      # +message+ its refusal) or :unknown (no such session, or a prefix of
      # several: +error+ the ArgumentError, a Session::AmbiguousId for the
      # latter; +message+ its message).
      Unsent = Data.define(:reason, :message, :asked, :error) do
        def initialize(reason:, message:, asked: nil, error: nil) = super
      end

      # One delivery made (#attempt): the session as read for it, its
      # +owner+ then, whether it was +running+, the +delivery+ asked for, the
      # image +refs+ copied in and the backend's DeliverResult (+result+:
      # accepted or not, continued or not).
      Attempted = Data.define(:target, :session, :owner, :running, :delivery, :refs, :result)

      # The caller's check refused the message before anything was sent.
      Stopped = Data.define(:target, :refusal)

      # @param access [#resolve, #head, #show, #owner, #deliver_turn, #wait_reply] a SessionAccess backend
      # @param pause [#call] sleeps between two looks at a continue in flight
      # @param continuing_wait [Numeric] seconds #locate waits for one
      # @param continuing_poll [Numeric] seconds between two looks
      # @param clock [#call] monotonic seconds
      # @param cancelled [#call] true ends a wait for a continue at the next
      #   look (chi web stopping): #locate answers Unsent, #relocate nil
      def initialize(access, pause: ->(seconds) { sleep(seconds) }, continuing_wait: CONTINUING_WAIT,
                     continuing_poll: CONTINUING_POLL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     cancelled: -> { false })
        @access = access
        @pause = pause
        @continuing_wait = continuing_wait
        @continuing_poll = continuing_poll
        @clock = clock
        @cancelled = cancelled
      end

      # +given+'s session (an id or a prefix), then where input for it goes
      # (the backend's #head): a continued session's chain's newest link. A
      # continue of it in flight (the new link not saved yet) is asked again
      # for up to continuing_wait, then refused; the old link is never
      # named (a send would un-archive it beside the new one).
      # @param deadline [Numeric, nil] this clock's seconds the wait for a
      #   continue ends by, if before continuing_wait (an ask's one deadline)
      # @return [Located, Unsent]
      def locate(given, deadline: nil)
        id = @access.resolve(given)
        head = @access.head(id)
        deadline = [@clock.call + @continuing_wait, deadline].compact.min
        waited = head.continuing?
        while head.continuing? && @clock.call < deadline && !@cancelled.call
          pause_until(deadline)
          head = @access.head(id)
        end
        return Unsent.new(reason: :continuing, message: head.continuing_refusal, asked: id) if head.continuing?

        Located.new(target: head, waited: waited)
      rescue ArgumentError => e
        Unsent.new(reason: :unknown, message: e.message, error: e)
      end

      # +refused+'s id (its +asked+) located again after a continue took
      # its link (a DeliverResult#continued?), pausing between looks while
      # it still names that link, until +deadline+ (this clock's seconds).
      # @param bounded [Boolean] each look's own wait for a continue ends by
      #   +deadline+ too (an ask's one deadline); false, it may wait its
      #   continuing_wait past it (chi send's)
      # @yieldparam located [Located] each look that waited on a continue
      #   (#locate's waited), whichever link it named
      # @return [Located, Unsent, nil] nil: out of time
      def relocate(refused, deadline, bounded: false)
        while @clock.call < deadline && !@cancelled.call
          pause_until(deadline)
          again = locate(refused.asked, deadline: (deadline if bounded))
          return again unless again.is_a?(Located)

          yield again if block_given? && again.waited
          next if again.target.id == refused.id

          return again
        end
        nil
      end

      # One delivery of +prompt+ to +target+: the session read, +check+
      # (a String refuses: nothing is sent), its owner, the images copied
      # in, then the turn. +queue+ always goes as a queue, idle or not;
      # +cut+ asks a running turn for a cut (an idle session's is an
      # ordinary message). No retry and no discard: a continued result is
      # returned as is, and the caller takes its refs back and relocates.
      # @param images [#upload, nil] answers upload(id) with the refs a turn
      #   takes (nil: none)
      # @param check [#call, nil] called with the session read: a refusal
      #   String, or nil to go on
      # @param enqueued_id [String, nil] the turn's id, the caller's (an
      #   ask's request_id): passed to deliver_turn only when given
      # @param anchors [TurnAnchors, Hash, nil] what the turn points at
      #   (TurnAnchors): passed to deliver_turn only when given
      # @return [Attempted, Stopped]
      def attempt(target, prompt, client_id:, queue: false, cut: false, images: nil, check: nil, enqueued_id: nil,
                  anchors: nil)
        id = target.id
        session = @access.show(id)
        if check && (refusal = check.call(session))
          return Stopped.new(target: target, refusal: refusal)
        end

        owner = @access.owner(id)
        running = owner && session.status == Session::STATUS_RUNNING
        refs = images ? images.upload(id) : []
        delivery = if queue then Delivery::QUEUE
                   elsif cut && running then Delivery::CUT
                   end
        more = { enqueued_id: enqueued_id, anchors: anchors }.compact
        result = @access.deliver_turn(id, prompt: prompt, client_id: client_id, images: refs, delivery: delivery,
                                          follow: target.via != :pinned, **more)
        Attempted.new(target: target, session: session, owner: owner, running: running, delivery: delivery, refs: refs,
                      result: result)
      end

      # The wait for an accepted message's own turn (ReplyWait::Target.message).
      # @param start [WaitStart] prepare_wait's, read before it went in
      def bind(start, result, queue:) = ReplyWait::Target.message(start, result, queue: queue)

      # The backend's wait for what +target+ binds: the result's turn_id is
      # the target's report_turn_id whenever that is known (even when the
      # wait took the next reply), its text UTF-8.
      # @param more [Hash] passed on (cancelled: for a Local backend)
      # @return [ReplyWait::Result]
      # @raise [ArgumentError] the session is gone
      def wait(id, target, timeout:, poll_interval: nil, **more)
        options = { timeout: timeout, **more }
        options[:poll_interval] = poll_interval if poll_interval
        result = @access.wait_reply(id, **target.to_h, **options)
        report_turn_id = target.report_turn_id
        result.turn_id = report_turn_id if report_turn_id && !report_turn_id.to_s.empty?
        result.text = result.text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
        result
      end

      # This exchange's clock, for a caller's deadline (#relocate's).
      def now = @clock.call

      private

      # One pause between two looks: continuing_poll, or less when
      # +deadline+ comes first.
      def pause_until(deadline) = @pause.call([@continuing_poll, deadline - @clock.call].min)
    end
  end
end
