# frozen_string_literal: true

require "securerandom"

require_relative "../child_reports"
require_relative "../client_id"
require_relative "../iteration_limit"
require_relative "../log"
require_relative "../peer_mailbox"
require_relative "../session_inbox"
require_relative "../turn_origin"

module Samagotchi
  class Worker
    # The turns nobody typed: a delegate report's wake (#run_wake_turn), a
    # finished task's (#run_task_wake), an attached context change's
    # (#run_context_wake_turn) and the due reminders (#run_due_reminders), and
    # the idle loop's sleep (#idle_wait). Glue over WorkerWakes, WorkerTaskWakes
    # and WorkerInbound: it writes no ivar of its own. Reads @child_reports,
    # @wakes, @turn_flow, @inbound, @continue_offer, @task_wakes, @engine,
    # @event_log, @session_dir and @poll_interval.
    module WakeTurnsPart
      # A reminder turn's origin: chi's own (system:reminder). Its run gets
      # an id of its own (#wake_origin); this constant has none.
      REMINDER_ORIGIN = TurnOrigin.new(client_id: ClientId::REMINDER)

      # A wake turn's minted enqueued_id starts with this
      # (SessionInbox::ENQUEUED_ID_NAME).
      WAKE_ID_PREFIX = "wake-"

      private

      # :due when an idle parent should run a turn for its delegate
      # children's reports now (session.delegate_reports: wake): rings wait,
      # no continue offer does (they merge into its turn), wakes aren't paused
      # by a failed one, and the wake budget isn't spent; :budget when only
      # the budget stops it; nil otherwise.
      def wake_state
        return nil unless @child_reports && ChildRing.mode == "wake"

        @wakes.delegate_state(awaiting_continue: @turn_flow&.awaiting_continue?) { @child_reports.waiting? }
      end

      # Run a turn nobody typed for the reports the rings bring (a wake turn):
      # a continue turn (no prompt bubble) whose first boundary merges them,
      # with origin child:<id8>. A failure goes back to the checkpoint, keeps
      # the rings and pauses wakes until a human's input (a provider outage
      # doesn't loop).
      # @return [Boolean] whether a wake turn ran
      def run_wake_turn
        return false if @wakes.in_grace?

        state = wake_state
        budget_notice if state == :budget
        return false unless state == :due

        # Unresolved: a relay among them opens its card at the turn's first
        # boundary, on the turn thread (a Stop closes it).
        reports, = take_child_reports(resolve: false)
        # The turn must not generate with nothing to say: the drain gets this
        # exact list at its first boundary.
        return false if reports.empty?

        @wakes.hand_over(reports)
        Log.info(:worker, "delegate_wake_turn", reports: reports.size, in_a_row: @wakes.count!)
        # Rolled back, the rings stay (settle_child_reports): the user's next
        # turn takes them. A turn that got somewhere stays, and read them.
        run_wake(origin: reports.first.origin,
                 failed: reports.size == 1 ? "a delegate's report" : "#{reports.size} delegate reports",
                 kept: "chi keeps #{reports.size == 1 ? "the report and brings it" : "the reports and brings them"} " \
                       "again with the user's next message.")
        true
      ensure
        @wakes.drop_handed
      end

      # The wake budget is spent: the parent's UIs hear once that reports
      # wait for the next message.
      def budget_notice
        return unless @wakes.notice_budget!

        count = SessionInbox.find_ring_files(@session_dir).map { |f| SessionInbox.read_ring(f)&.dig(:child_id) }.uniq.size
        @event_log.announce(type: :hook_notice, hook: "delegate", level: :info, between_turns: true,
                            text: "#{count} delegate report#{"s" if count != 1} waiting; #{count == 1 ? "it joins" : "they join"} " \
                                  "your next message (#{@wakes.max} turn#{"s" if @wakes.max != 1} ran for reports in a row, #{ChildRing::MAX_WAKES_KEY})")
      end

      # A wake turn (a delegate report's, an attached context change's, a
      # finished task's): a continue turn nobody typed, from +origin+. A
      # failure goes back to before the turn and pauses wakes until a human's
      # input (a provider outage doesn't loop); so does a Stop before it got
      # anywhere (a Stop or a before_turn hook's cancel before the model
      # call, restored by TurnFlow), rather than waking again at once. Either
      # way +mark+ (a WorkerInbound::ContextWake or TaskWake: its wake note,
      # the turn's first message) goes back to a plain note
      # (WorkerInbound#unmark_wake), unless the failed turn kept its steps.
      # +failed+ names the wake in the failed turn's note, +kept+ says what
      # happens to it (TurnFlow#prompt_turn_failed).
      def run_wake(origin:, failed:, kept: nil, mark: nil)
        @turn_flow.before_prompt_turn
        restores = @turn_flow.restores
        run_engine_turn(nil, continue: true, origin: wake_origin(origin), id: mark&.turn_id,
                             max_iterations: IterationLimit.for) do |result, error|
          if error
            steps_kept = @turn_flow.prompt_turn_failed(error: error, wake: failed, wake_kept: kept) == :kept
            @unmarked_this_turn = @inbound.unmark_wake(mark) if mark && !steps_kept
            @wakes.pause!
          else
            @continue_offer.after_turn(result)
            if result.canceled? && @turn_flow.restores != restores
              @unmarked_this_turn = @inbound.unmark_wake(mark) if mark
              @wakes.pause!
            end
          end
        end
      end

      # A turn nobody typed for a changed source (a context wake): a continue
      # turn from context:<name> whose first message is the wake note already
      # in the conversation (named by +turn_id+), on the same rules as a
      # delegate report's wake turn (#run_wake): it counts toward
      # session.max_wakes (a peer's answer toward context.peer_turns too,
      # unless it agrees).
      # +context_wake+: a WorkerInbound::ContextWake.
      def run_context_wake_turn(context_wake)
        name = context_wake.name
        Log.info(:worker, "context_wake_turn", name: name, in_a_row: @wakes.count!(peer: context_wake.peer_turn?))
        run_wake(origin: context_wake.origin, failed: "the change in attached context #{name}", mark: context_wake)
      end

      # A turn nobody typed for a peer's message that asked (a mail wake): a
      # continue turn from peer:<name> whose first message is the batch's
      # last note, already in the conversation (named by its turn id), on
      # #run_wake's rules. It counts toward session.max_wakes and, unless the
      # message agrees, toward context.peer_turns.
      # +mail_wake+: a WorkerInbound::MailWake.
      def run_mail_wake_turn(mail_wake)
        Log.info(:worker, "mail_wake_turn", peer: mail_wake.peer, in_a_row: @wakes.count!(peer: !mail_wake.agreed))
        run_wake(origin: mail_wake.origin, failed: "the message from your peer agent #{PeerMailbox.label(mail_wake.peer)}",
                 mark: mail_wake)
      end

      # The background tasks this session started that finished unseen, as
      # notes (WorkerTaskWakes#take), and the wake turn the first one may
      # start.
      # @return [Boolean] whether a wake turn ran
      def run_task_wake
        task_wake = @task_wakes.take
        return false unless task_wake

        run_task_wake_turn(task_wake)
        true
      end

      # A turn nobody typed for a finished task: a continue turn from
      # task:<id> whose first message is the wake note, on the delegate wake's
      # rules (#run_wake; counted toward session.max_wakes): a failure that
      # kept nothing, or a Stop that restored the conversation, leaves the
      # note as a plain one (M4).
      def run_task_wake_turn(task_wake)
        Log.info(:worker, "task_wake_turn", task_id: task_wake.id, in_a_row: @wakes.count!)
        run_wake(origin: task_wake.origin, failed: "a finished background task (#{task_wake.name.delete_prefix("task ")})",
                 kept: "Its note stays for the user's next message.", mark: task_wake)
      end

      # A due reminder runs as a continue turn: Engine#run_turn
      # injects the reminders as a tail system message, and no user message is
      # added. A prompt's turn may have injected them already (a stale latch):
      # then there is nothing to run.
      # @return [Boolean] whether a reminder turn ran
      def run_due_reminders
        return false if @engine.due_reminder_names.empty?

        @engine.clear_due_reminder_names!
        return false unless @engine.reminders_due?

        @continue_offer.drop(REMINDER_ORIGIN)
        # A failure has no prompt to hand back (the Engine announced
        # :turn_failed). The offer went before the turn
        # (ContinueOffer#drop); either way the rollback window closes.
        run_engine_turn(nil, continue: true, origin: wake_origin(REMINDER_ORIGIN),
                             max_iterations: IterationLimit.for) { @turn_flow.after_reminder_turn }
        true
      end

      # A turn nobody typed (a reminder, a wake) with an enqueued_id of its
      # own, minted here as it runs, so its checkpoint mark, last_turn, reply
      # file and settle name it (a wait with no message binds it:
      # ReplyWait.own_turn). Never on the origin constants nor on
      # ChildReports::Report#origin: a report merged into a turn keeps an
      # id-less origin, which the web page reads as a report (turn_events.js
      # promptOps), not as an unmatched steer.
      # @return [TurnOrigin] +origin+ with an id ("wake-<16 hex>")
      def wake_origin(origin)
        origin.enqueued_id ? origin : origin.with(enqueued_id: "#{WAKE_ID_PREFIX}#{SecureRandom.hex(8)}")
      end

      # The idle loop's sleep: the fallback tick, or less while reports or
      # attached-context wakes wait out the start grace.
      def idle_wait
        @wakes.idle_wait(@poll_interval) { wake_state == :due || @inbound.context_wake_waiting? || @inbound.mail_wake_waiting? }
      end
    end
  end
end
