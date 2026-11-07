# frozen_string_literal: true

module Samagotchi
  class Engine
    # The session messages API: out-of-turn edits to the current session's
    # conversation (replace, append, a context note, rollback), its
    # checkpoints and last answer, and the running turn's live conversation.
    # Reads @session and @kernel; every edit goes through
    # #replace_session_messages.
    module MessagesPart
      # The strategy the working set is built under now, as LLMContextView
      # takes it: the running turn's, else the next turn's (#emit_working_set).
      # /working-set's ops act under it.
      # @return [Symbol, Array<Symbol>]
      def working_set_strategy
        working_set_llm_context&.strategy || LLMContextView::NONE
      end

      # Replace the current session's conversation, between turns (a
      # /working-set op's copy: #clone_messages, then its edits).
      # @param messages [Array<Hash>]
      # @return [Array<Hash>] the session's messages
      def replace_messages(messages)
        raise ArgumentError, "no current session" unless @session

        replace_session_messages(@session, messages)
      end

      # Add a context note to the session's conversation, between turns: a
      # tail system message the next turn sees, announced as :context_added.
      # The array is replaced, not mutated, and the append and the event
      # happen under the event lock, so a joining UI sees both or neither.
      # The caller saves the session.
      # @param note [Hash] SessionInbox.read_note's shape
      # @return [Hash, nil] the message, or nil when the conversation already
      #   holds this note (a note file re-read after a crash)
      def add_context_note(session, note)
        synchronize_events do
          next nil if Array(session.messages).any? { |m| m[:note_id] == note[:note_id] }

          message = ContextNote.message(**note)
          entry = note[:objectives] && Objectives.entry(note[:objectives], before: Objectives.build(session.messages))
          replace_session_messages(session, Array(session.messages) + [message])
          announce({ type: :context_added, session_id: session.id, note_id: note[:note_id], source: note[:source],
                     label: ContextNote.label_of(message), from_session: note[:from_session],
                     from_cwd: note[:from_cwd], text: note[:text], context_source: note[:context_source],
                     created_at: note[:created_at], objectives: entry }.compact)
          announce_objectives(session) if entry
          @objectives_stage.note(session, note)
          message
        end
      end

      # ── Session messages API ───────────────────────────────────────────────
      #
      # Out-of-turn edits to the current session's conversation (`!cmd` output,
      # rollback after Ctrl-C). Each replaces the array rather than mutating it,
      # so the recap's lock-free snapshot never sees a half-applied edit.

      # The answer a UI shows last (AnswerTail), a copy of that one message
      # only: walked back from the end, never a #messages_checkpoint of the
      # whole conversation (the Bridge's GET tail). +turn_id+: that turn's
      # answer (AnswerTail.find); unknown or nil: the newest.
      # @return [Hash, nil]
      def last_answer_message(turn_id: nil)
        AnswerTail.find(@session&.messages, turn_id: turn_id)&.dup
      end

      # @return [Array<Hash>] a copy of the current session's messages to hand
      #   back to #rollback_to later
      def messages_checkpoint
        clone_messages(@session&.messages)
      end

      # The running turn's conversation as its loop builds it (both loops
      # register it on the kernel's llm_context_turn): the same array the loop
      # appends to, not a copy, so read it on the turn's thread (the pending
      # input drain, at an iteration boundary: TurnCheckpoint), or from another
      # only as a dup, read only (/objectives). nil when no turn runs, and
      # while the running turn's loop has yet to register its own
      # (llm_context_turn is never cleared, and still holds the last turn's
      # then: its turn_id tells them apart).
      # @return [Array<Hash>, nil]
      def live_conversation
        running = turn_context
        return nil unless running && @kernel.respond_to?(:llm_context_turn)

        forget = @kernel.llm_context_turn
        forget&.turn_id == running.id ? forget.conversation : nil
      end

      # Append messages to the current session's conversation.
      # @param messages [Array<Hash>]
      # @return [Array<Hash>] the session's messages
      def append_messages(messages)
        raise ArgumentError, "no current session" unless @session

        replace_session_messages(@session, Array(@session.messages) + clone_messages(messages))
      end

      # Restore the current session's conversation to a #messages_checkpoint.
      # Between turns the working set is announced when that changed it (a
      # !rollback or a canceled continue dropping the turn's tool calls, the
      # set emptied too), so the page doesn't keep the dropped items until
      # the next request.
      # @param checkpoint [Array<Hash>]
      # @return [Array<Hash>] the session's messages
      def rollback_to(checkpoint)
        raise ArgumentError, "no current session" unless @session

        messages = replace_session_messages(@session, clone_messages(checkpoint))
        unless turn_running?
          announce_working_set
          announce_objectives
        end
        messages
      end

      # Clone a messages array (shallow dup of each element).
      # @param messages [Array<Hash>]
      # @return [Array<Hash>]
      def clone_messages(messages)
        Array(messages).map(&:dup)
      end
    end
  end
end
