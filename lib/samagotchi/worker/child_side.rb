# frozen_string_literal: true

require "fileutils"

require_relative "../child_reports"
require_relative "../client_id"
require_relative "../continue_offer"
require_relative "../llm/errors"
require_relative "../log"
require_relative "../verify_fresh"

module Samagotchi
  class Worker
    # A delegate child's rings to its parent and the Verify fresh hand-off:
    # #forward_fresh_verdicts (the child's side), #absorb_fresh_verdicts (the
    # parent's half), #settle_child_reports, #merges_lost?,
    # #ring_parent_after_turn, #reports_to_parent? and #ring_question. The
    # name is the audit's; #absorb_fresh_verdicts is the parent's half of the
    # Verify fresh hand-off. Writes @owes_parent, @asked_parent and
    # @reporting_turn (also written by #run_engine_turn, with @initial_turn
    # from #run_initial_prompt; #initialize sets them). Reads @session,
    # @state_dir, @session_dir, @engine, @child_reports and @initial_turn.
    module ChildSidePart
      private

      # A Verify fresh child's verdicts this turn recorded go to its parent
      # (VerifyFresh.forward), after the save: the parent's card shows them.
      # A fresh child never rings (ChildRing.ring): nothing enters the
      # parent's conversation.
      def forward_fresh_verdicts(before)
        return unless @session.verify_fresh

        added = @session.verdicts.drop(before)
        VerifyFresh.forward(@session, added, state_dir: @state_dir) unless added.empty?
      end

      # The parent's side, between turns: the verdicts its Verify fresh
      # children forwarded join the session's (saved, then their files go)
      # and the UIs hear each (:verdict_recorded).
      def absorb_fresh_verdicts
        added, files = VerifyFresh.take(@session, @session_dir)
        return if files.empty?

        return unless save_or_log(:fresh_verdicts) { save_session }

        FileUtils.rm_f(files)
        added.each { |record| @engine.announce(type: :verdict_recorded, verdict: record) }
      rescue StandardError => e
        Log.warn(:worker, "fresh_verdicts_failed", error: e.class.name, msg: e.message)
      end

      # The delegate reports this turn took: a kept turn moves the cursors on
      # and deletes their rings; a rolled-back one leaves the rings for the
      # next turn. Once either way: the model reads a report in the
      # conversation, or the next turn brings it (unless a later !rollback
      # erases a kept turn, which drops what it read).
      def settle_child_reports(rolled_back:)
        rolled_back ? @child_reports.release : @child_reports.commit
      end

      # Whether +error+ ended the turn without its loop's conversation: a
      # failure the loops didn't mark (LLM::FailedTurn), one past their end
      # (the Engine's own end of the turn, say). The Engine kept the turn's
      # start only, so the reports its loop merged are not in the
      # conversation: their rings stay for the next turn, even when the turn
      # itself stays (a reminder or continue turn). Not one raised after the
      # turn ended (the Engine's post-turn work): the turn was kept as it
      # ended, completed or canceled, the reports in it (a turn TurnFlow
      # takes back is a restore, above).
      def merges_lost?(error)
        return false if error.nil? || error.is_a?(LLM::FailedTurn)

        !KEPT_TURN_OUTCOMES.include?(@session.last_turn&.outcome)
      end

      # The Engine's turn endings that keep the turn's conversation (#merges_lost?).
      KEPT_TURN_OUTCOMES = %w[completed canceled].freeze

      # A delegate child's turn that was its parent's (#reports_to_parent?)
      # rings the parent, after the save: the parent reads a settled child.
      # A question it rang about that still waits makes the next turn ring
      # too, whoever starts it (the user answering Continue on the web).
      def ring_parent_after_turn
        ChildRing.ring(@session, why: "turn_end", state_dir: @state_dir) if @reporting_turn
        @owes_parent = @asked_parent && !@session.pending_question.nil?
        @asked_parent = false
        @reporting_turn = false
      end

      # Whether the turn starting now is a delegate child's parent's: its
      # task (the initial prompt), a follow-up, a continue the parent
      # answered, a reminder, anything but a human typing into the child
      # (ClientId.human?), and any turn after a question the parent
      # was rung about.
      def reports_to_parent?(origin)
        return false unless @session.delegate?

        @initial_turn || @owes_parent || !ClientId.human?(origin.client_id)
      end

      # The Engine published a question (after the question desk saved it).
      # In a turn that reports to the parent, the model's own question, the
      # step-limit continue and a hook's question ring it (the parent reports
      # or relays a hook's: ChildReports). Approvals don't: the relay takes
      # them while the parent waits. Nor does a card relayed from this
      # session's own child (relay set): the hop is the parent's wait.
      def ring_question(event)
        return unless @reporting_turn

        pending = event[:pending_question] || {}
        kind = pending[:kind].to_s
        return unless RINGING_KINDS.include?(kind)
        return if pending[:relay]

        ChildRing.ring(@session, why: "question", state_dir: @state_dir)
        @asked_parent = true
      end

      # The kinds of question that ring a delegate child's parent (#ring_question).
      RINGING_KINDS = ["", ContinueOffer::KIND, "hook"].freeze
    end
  end
end
