# frozen_string_literal: true

require_relative "../archive_store"
require_relative "../child_reports"
require_relative "../client_id"
require_relative "../log"
require_relative "../turn_checkpoint"
require_relative "../visitor"

module Samagotchi
  class Worker
    # Who a turn's input came from and what it does to the session: the
    # owner's input (#user_input: un-archive, wake reset, held reports), the
    # driver's (the same but the un-archive), a visitor's count toward
    # session.max_wakes and its refusal (#count_visitor, #refuse_visitor),
    # and the one seat for refusing a queued turn (#refuse_queued_turn).
    # Reads @session, @session_id, @state_dir, @session_dir, @wakes,
    # @child_reports and @event_log.
    module SendersPart
      private

      # A visitor's turn (an agent's that doesn't drive the session: Visitor)
      # counts toward session.max_wakes, the budget wake turns use, before
      # anything else runs for it (no start grace, context.wake or pause
      # gate: its sender asked for it).
      # @return [Boolean] false when the budget is spent: refuse it
      def count_visitor
        return false if @wakes.spent?

        @wakes.count!
        true
      end

      # The owner's input (ClientId.owner?) un-archives the session; a
      # delegate's, a plugin's, a reminder's or a participant's doesn't.
      # It also resets the wakes (budget and pause); input typed in the web or
      # a TUI the peer wakes too (chi send doesn't: a peer can run it).
      def user_input(client_id)
        # The session's driver (an agent: Visitor.driver?) resets the wake
        # budget and releases held reports as chi send's input did, but never
        # brings back an archived session.
        if Visitor.driver?(client_id, @session)
          @wakes.human_input!(interactive: false)
          @child_reports&.release_holds
          return
        end
        return unless ClientId.owner?(client_id)

        ArchiveStore.user_input(@session_id, state_dir: @state_dir)
        @wakes.human_input!(interactive: ClientId.interactive?(client_id))
        @child_reports&.release_holds
      end

      # session.max_wakes spent: a visitor's queued turn is refused (its
      # sender's wait reads ParentReport::REFUSED_LINES' max_wakes); the
      # owner hears it once, until their next message (WorkerWakes#notice_visitor!).
      def refuse_visitor(origin)
        Log.info(:worker, "visitor_turn_refused", client_id: origin.client_id, reason: Visitor::CAP_REASON)
        refuse_queued_turn(origin, Visitor::CAP_REASON)
        return unless @wakes.notice_visitor!

        name = ClientId.agent_name(origin.client_id)
        @event_log.announce(type: :hook_notice, hook: "agent", level: :info, between_turns: true,
                            text: "#{name}'s message was not run: #{@wakes.max} turns ran in a row with no message " \
                                  "from you (#{ChildRing::MAX_WAKES_KEY}); agents' messages run again after your next one")
        nil
      end

      # A queued turn that may not start (a participant's, WorkerParticipantGate#refuse):
      # settled as refused for +reason+ (a code) and dropped from every UI's
      # queue; it never runs (TurnCheckpoint.refuse_queued).
      # @return [nil]
      def refuse_queued_turn(origin, reason, author: nil)
        TurnCheckpoint.refuse_queued(@session_dir, @event_log, origin, reason, author: author)
      end
    end
  end
end
