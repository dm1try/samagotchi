# frozen_string_literal: true

require_relative "../guardrails/parent_policy"
require_relative "../log"
require_relative "../session"
require_relative "../session_inbox"
require_relative "../turn_checkpoint"
require_relative "../worker_inbound"

module Samagotchi
  class Worker
    # The start-up settle, before the Bridge serves: #settle_interrupted_turn,
    # #settle_stale_status, #prune_tombstones, #announce_session_warnings and
    # #drop_dead_question. Called by #start and #serve only; no state of its
    # own. Writes @session (the interrupted turn's end, the stale status, a
    # dead question) and saves it. Reads @session, @session_dir, @session_id,
    # @state_dir and @engine.
    module StartupPart
      private

      # A turn an earlier worker died in (TurnCheckpoint's mark in the file):
      # ended now as canceled, with its note, and saved, before the Bridge
      # serves the session (TurnCheckpoint.settle). Its queued id's wait
      # (chi send --queue --wait) reads the end it records in the session dir.
      def settle_interrupted_turn
        mark = TurnCheckpoint.settle(@session, session_dir: @session_dir)
        return unless mark

        Log.info(:worker, "interrupted_turn_settled", turn_id: mark.id, iteration: mark.iteration, at: mark.at)
        save_or_log(:interrupted_turn) { save_session }
      end

      # No turn runs yet: a status a turn would be behind is from before this
      # worker, and goes idle under the lock (resume_session writes nothing to
      # the file, which this worker owns): a stopped one with no stop marker
      # (Session.load reads it stopped while the marker is there; a stop that
      # landed before an earlier worker took the lock saved it so), an error,
      # a running whose worker died. Not a new session's running whose first
      # prompt waits (WorkerInbound.initial_prompt_pending?).
      STALE_STATUSES = [Session::STATUS_STOPPED, Session::STATUS_ERROR, Session::STATUS_RUNNING].freeze

      #
      # Saved whatever the status: the save stamps updated_at, which a resume
      # used to move (an old session woken with no turn, an attach or a web
      # wake, stays young for the sweep and moves up the lists). Not a
      # stopped one: this worker leaves at once, and would write "stopped".
      def settle_stale_status
        return if Session.stopped_marker?(@session_id, state_dir: @state_dir)

        status = @session.status
        if STALE_STATUSES.include?(status) && !(status == Session::STATUS_RUNNING && WorkerInbound.initial_prompt_pending?(@session))
          @session.status = Session::STATUS_IDLE
          Log.info(:worker, "stale_status_settled", status: status)
        end
        save_or_log(:worker_start) { save_session }
      end

      # The per-input tombstones (removed, settled, merged) older than
      # SessionInbox::TOMBSTONE_MAX_AGE, once per worker start: they only go
      # with the session dir otherwise.
      def prune_tombstones
        removed = SessionInbox.prune_removed(@session_dir)
        settled = TurnCheckpoint.prune_settled(@session_dir)
        merged = SessionInbox.prune_merged(@session_dir)
        Log.info(:worker, "tombstones_pruned", removed: removed, settled: settled, merged: merged) if (removed + settled + merged).positive?
      end

      # A saved parent_answers that isn't a level reads as hard on every
      # answer without a word; said once here, as the session loads.
      def announce_session_warnings
        value = @session.parent_answers
        return unless Guardrails::ParentPolicy.unknown_level?(value)

        @engine.announce({ type: :guardrail_warning, label: "parent_answers",
                           message: "parent_answers #{value.inspect} in session #{@session_id} isn't hard/standard/soft; hard applies" })
      end

      # A question saved by a worker that died while it waited (an
      # ask_user_question, an approval, a hook's question): the turn that
      # asked is gone, so nobody can answer it, and left in the file it
      # would keep the hub's "needs you" badge on for good. Dropped and saved
      # before the Engine and the Bridge exist (no question lock, no events).
      def drop_dead_question
        id = @session.drop_dead_question
        return unless id

        Log.info(:worker, "dead_question_dropped", id: id)
        save_or_log(:dead_question) { save_session }
      end
    end
  end
end
