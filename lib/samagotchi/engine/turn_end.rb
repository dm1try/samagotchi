# frozen_string_literal: true

module Samagotchi
  class Engine
    # How a turn ends after #end_turn's step: the normal ending and its
    # after-turn hooks, a stop before the model, the release, what an ending
    # keeps (TurnEndings, forwarded), last_turn, the answer's display.
    # Writes @last_context_status; reads @turn_endings, @turn_state,
    # @steer_cut, @hooks, @session_observer, @client.
    module TurnEndPart
      # How the turn ended, on the session (Session#last_turn): the caller's
      # save puts it in the file the session hub watches. Public for the
      # Worker's turn that failed before it began (no #end_turn ran).
      # @param limit [Integer, nil] the turn ran out of iterations at this
      #   limit: "exhausted" => true, "limit" => N, so a wait with nobody to
      #   answer the continue offer says so (ReplyWait, ParentReport "limit")
      # @param origin [TurnOrigin] the turn's (TurnOrigin::NONE for no sender)
      # @param event [Hash] the turn's end event (#stop_facts)
      def record_last_turn(session, outcome, seconds, origin, event, limit: nil)
        enqueued_id = origin.enqueued_id
        session.last_turn = LastTurn.new(outcome: outcome, ended_at: Time.now.iso8601(3), seconds: seconds.round(1),
                                         origin: origin.source, exhausted: limit ? true : nil, limit: limit,
                                         enqueued_id: enqueued_id.to_s.empty? ? nil : enqueued_id.to_s,
                                         author: origin.participant_author,
                                         **stop_facts(event))
      end

      # Why a turn stopped (TurnEndings#stop_facts).
      def stop_facts(event) = @turn_endings.stop_facts(event)
      private :stop_facts

      def save_quietly(session)
        session.save(state_dir: session_state_dir)
      rescue StandardError => e
        Log.warn(:turn, "turn_end_save_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        nil
      end
      private :save_quietly

      # Keep what the after_turn hooks presented as the answer's `display`
      # and the refs they attached as its `display_refs` (AnswerRefs, one
      # replace for both), and tell the observers (:answer_display, the
      # display or nil, and how many refs), after the turn_completed they
      # already had: the web re-reads the answer then. A turn_completed
      # with display_pending (after_turn hooks were about to run) always gets
      # one, `display: nil` when nothing was presented, so the web holds the
      # answer's pop until then and never swaps it after. Terminals are not
      # sinks of it; they printed the answer already. The session is saved by
      # the caller, as after every turn.
      def store_answer_display(session, display, refs, pending: false)
        synchronize_events do
          # A plugin that kept event[:refs] and calls it later gets nil: the
          # list is stored now (and the turn is over on every path).
          refs.close!
          messages = Array(session.messages)
          changed = display.changed? && messages.last.equal?(display.target)
          added = refs.added? && messages.last.equal?(refs.target)
          if changed || added
            merged = messages.last.dup
            merged[AnswerDisplay::KEY] = display.text if changed
            merged[AnswerRefs::KEY] = refs.to_a if added
            replace_session_messages(session, messages[0...-1] + [merged])
            event = { type: :answer_display, display: changed ? display.text : nil }
            event[:refs] = refs.count if added
            @session_observer.notify(event)
          elsif pending
            @session_observer.notify({ type: :answer_display, display: nil })
          end
        end
      end
      private :store_answer_display

      # A turn stopped before the model was asked (#prepare_turn returned
      # false): canceled with nothing kept, like a Ctrl-C there; the result
      # has no conversation, so a UI's checkpoint stands.
      def stopped_before_model(turn)
        reason = turn.controller.reason
        end_turn(turn, "canceled") do |seconds|
          [nil, { type: :turn_canceled, cancellation_reason: reason, cancelled_by: cancelled_by(turn),
                  duration_ms: (seconds * 1000).round }]
        end
        LLM::ModelResult.new(text: "", canceled: true, cancellation_reason: reason)
      end
      private :stopped_before_model

      # Who stopped a turn a hook stopped or cut (the controller's detail: the
      # bundle, or the hook's label), for the UIs' "stopped by loop-guard";
      # nil for any other cancel.
      def cancelled_by(turn) = turn.controller.stopped_by
      private :cancelled_by

      # The normal ending (an answer, an empty answer, a Stop, the iteration
      # limit), then the after-turn hooks.
      def complete_turn(turn, result)
        canceled = result.canceled?
        # after_turn hooks run below and may present the answer (the web
        # holds its pop until it knows).
        display_pending = !canceled && @hooks.any?(:after_turn)
        end_turn(turn, canceled ? "canceled" : "completed", exhausted: !canceled && result.exhausted?) do |seconds|
          kept = kept_messages(turn, result, seconds)
          if canceled
            [kept, { type: :turn_canceled, cancellation_reason: result.cancellation_reason, cancelled_by: cancelled_by(turn),
                     duration_ms: (seconds * 1000).round }]
          else
            # For a client that attaches later (session_state_snapshot).
            @last_context_status = result.context_status.dup if result.context_status
            [kept, { type: :turn_completed, result: result, turn_summary: turn_summary(result),
                     display_pending: display_pending }]
          end
        end

        # Fire :after_turn hook (an answer or a Stop; an Interrupt or a failure
        # ends the turn in #run_turn without it), with a read-only
        # copy of the conversation the turn stored, event[:answer] (the answer's
        # text: the native loop's stored message still holds its thought),
        # event[:present] for
        # a display version of the answer (AnswerDisplay) and event[:refs]
        # for refs on it (AnswerRefs).
        session = turn.session
        unless canceled || result.exhausted?
          @objectives_stage.outgoing(turn, result, recorder: system_one_recorder)
          track_objectives_after(turn)
        end
        display = AnswerDisplay.new(session.messages)
        refs = AnswerRefs.new(session.messages, cwd: session.working_directory)
        after_turn = { type: :after_turn, status: canceled ? "canceled" : "completed",
                       messages: hook_messages(session.messages),
                       answer: (result.text unless canceled || result.exhausted?) }
        after_turn[:present] = display.presenter(after_turn)
        after_turn[:refs] = refs.adder(after_turn)
        @hooks.fire(:after_turn, after_turn)
        store_answer_display(session, display, refs, pending: display_pending)

        # Fire :session_end after the turn (turn-level lifecycle), as :after_turn
        @hooks.fire(:session_end, { type: :session_end, session_id: session.id })
      end
      private :complete_turn

      # What each turn ending keeps and announces is TurnEndings'
      # (#build_turn_endings); these forward to it.
      def kept_messages(turn, result, seconds) = @turn_endings.kept_messages(turn, result, seconds)
      private :kept_messages
      def ctrl_c_messages(turn, interrupt, seconds) = @turn_endings.ctrl_c_messages(turn, interrupt, seconds)
      private :ctrl_c_messages
      def loop_conversation(error) = @turn_endings.loop_conversation(error)
      private :loop_conversation
      def failed_messages(turn, error) = @turn_endings.failed_messages(turn, error)
      private :failed_messages
      def failed_event(error, seconds) = @turn_endings.failed_event(error, seconds)
      private :failed_event

      # However the turn ended (#run_turn's ensure): the turn flag off, the
      # probe cancel restored, the cancel controller, sink and steers cleared
      # (a steer left is logged as dropped), activity recorded, the
      # turn-scoped hooks cleared.
      def release_turn(probe_cancel_before)
        # A completed turn is activity: release the turn flag and advance the
        # shared inactivity clock so the idle recap detector
        # treats the just-finished turn as activity and re-arms its window.
        left = @turn_state.finish!
        @steer_cut.finished!
        Client.swap_probe_cancel(probe_cancel_before)
        # The next turn's window and served model are asked again: the cache
        # (this host's, process-wide) is dropped here, at the turn's end,
        # rather than at its start, so what this turn read (the profile's own
        # probe included) is not asked for a second time within the turn. A
        # restart with another -c between turns is still noticed: the next
        # turn's first probe goes to the server.
        @client.invalidate_context_window!
        log_dropped_steers(left, "turn_ended")
        record_activity
        # Clear hooks so they remain turn-scoped and never leak into the next turn.
        clear_hooks
      end
      private :release_turn

      # JSON-safe digest of a finished turn for renderers (TurnEndings#turn_summary).
      # @param result [LLM::ModelResult]
      # @return [Hash]
      def turn_summary(result) = @turn_endings.turn_summary(result)
    end
  end
end
