# frozen_string_literal: true

require_relative "output_formatter"
require_relative "turn_note"
require_relative "context_note"
require_relative "llm/errors"

module Samagotchi
  # The state around turns that the REPL and a session worker share, kept out
  # of either loop: the pre-turn checkpoint (what !rollback and a failed turn
  # restore), the continue offer after a turn that ran out of iterations, and
  # the checkpoint a continue turn starts from.
  #
  # It edits the conversation only through the Engine's out-of-turn messages
  # API (messages_checkpoint / rollback_to / append_messages); saving the
  # session and telling the user are the host's.
  class TurnFlow
    CONTINUE_COMMAND = "/continue"
    SUMMARY_PROMPT_LIMIT = 600
    SUMMARY_MODEL_LIMIT = 360
    SUMMARY_PARAMS_LIMIT = 80
    SUMMARY_TOOLS_LIMIT = 5

    # Read an answer to the continue offer.
    # @return [Array(Symbol, String|nil)] [:resume | :abort | :abort_with_reason | :invalid, reason]
    def self.continue_decision(input)
      normalized = input.to_s.strip
      return [:resume, nil] if normalized.empty?

      lowered = normalized.downcase
      return [:resume, nil] if [CONTINUE_COMMAND, "yes", "y"].include?(lowered)
      return [:abort, nil] if %w[no n].include?(lowered)

      reason_match = normalized.match(/\A(?:no|n)\s*[,:-]\s*(.+)\z/i)
      if reason_match
        reason = reason_match[1].to_s.strip
        return [:abort, nil] if reason.empty?

        return [:abort_with_reason, reason]
      end

      [:invalid, nil]
    end

    # @return [Hash, nil] the pending continue offer: {context:, no_interrupt:}
    #   (context summarizes the interrupted turn for a "no, <reason>")
    attr_reader :offer

    # How many times the conversation went back to a checkpoint (a failed
    # or canceled turn's restore, !rollback): a worker compares it across a
    # turn to tell whether the turn's messages (the delegate reports it
    # merged) left the conversation.
    attr_reader :restores

    def initialize(engine:)
      @engine = engine
      @checkpoint = nil
      @continue_checkpoint = nil
      @offer = nil
      @restores = 0
    end

    def awaiting_continue? = !@offer.nil?

    # A prompt turn is about to start: remember the conversation before it.
    def before_prompt_turn
      @checkpoint = @engine.messages_checkpoint
    end

    # A continue turn is about to start: a cancel goes back to here.
    def before_continue_turn
      @continue_checkpoint = @engine.messages_checkpoint
    end

    # Take a turn's result.
    # @param continue [Boolean] it was a continue turn
    # @param no_interrupt [Boolean] the turn ran with no iteration limit to
    #   speak of; an offer it makes keeps that for its continue turn
    # @return [Symbol] :completed, :continue_offered, :cancelled (a prompt
    #   turn: its partial progress stays, !rollback can undo it) or
    #   :continue_cancelled (back to before the continue; the offer stays)
    def after_turn(result, continue: false, no_interrupt: false)
      if result.canceled?
        if continue
          restore(@continue_checkpoint)
          return :continue_cancelled
        end

        # The kernel salvaged the completed tool calls and the partial reply
        # into the conversation; without one, the turn leaves nothing.
        restore(@checkpoint) if @checkpoint && !conversation_of(result)
        @offer = nil
        return :cancelled
      end

      if result.resumable?
        @offer = { context: interrupted_turn_context(result), no_interrupt: no_interrupt }
        :continue_offered
      else
        @offer = nil
        @checkpoint = nil
        :completed
      end
    end

    # A prompt turn (or a wake turn) failed. One that got somewhere (the
    # Engine kept its tool results: LLM::FailedTurn.kept_steps, never for
    # a context overflow) stays, as after a cancel: its tool calls ran, and
    # the model must see what they did. The checkpoint stays for !rollback, and
    # the prompt is answered by what the turn did, so it doesn't go back to
    # its sender. One that got nowhere goes back to the conversation before
    # it, and its prompt to its sender (the caller hands it back).
    # Either way the note at the tail says why (TurnNote.failed), in place
    # of an older one, so the model reads why its last message went
    # unanswered.
    # @param error [Exception, nil] what failed: its one line is the note's
    # @param wake [String, nil] what woke the turn (TurnNote.failed's wake:)
    # @param wake_kept [String, nil] what becomes of the wake's news when
    #   the turn is rolled back (TurnNote.failed's kept:)
    # @param note [Boolean] false: no note (an image that never reached the
    #   model)
    # @return [Symbol] :kept or :restored
    def prompt_turn_failed(error: nil, wake: nil, wake_kept: nil, note: true)
      summary = error && (error.respond_to?(:summary) ? error.summary : error.message)
      steps = LLM::FailedTurn.kept_steps(error)
      @offer = nil
      if steps
        # The Engine's note says so already; a wake turn's says what woke it.
        if wake && note
          @engine.rollback_to(TurnNote.replace_trailing(@engine.messages_checkpoint,
                                                        TurnNote.failed(summary, wake: wake, steps: steps)))
        end
        return :kept
      end

      failed = note && summary && TurnNote.failed(summary, restored: wake.nil?, wake: wake, kept: wake_kept)
      if @checkpoint
        restore(@checkpoint, note: failed)
      elsif failed
        @engine.rollback_to(TurnNote.replace_trailing(@engine.messages_checkpoint, failed))
      end
      @checkpoint = nil
      :restored
    end

    # Answer the offer with no (Stop): the interrupted turn stays, as
    # after a Ctrl-C or a new prompt (!rollback still erases it), and the
    # model reads that it wasn't continued: a note, or the user's reason
    # (with a summary of that turn).
    def abort_continue!(reason: nil)
      message = reason ? { role: "user", content: reason_message(reason) } : TurnNote.not_continued
      @engine.append_messages([message])
      @offer = nil
    end

    # A new prompt came instead of an answer (a worker takes it): the offer
    # is gone and the partial turn stays, as after a Ctrl-C.
    def drop_offer!
      @offer = nil
    end

    # Restore the pre-turn checkpoint (!rollback after a Ctrl-C). A pending
    # offer goes too: the turn it offered to continue is gone. (The REPL
    # reads every line as an answer while an offer is pending; a worker
    # also takes !rollback then.)
    # @return [Boolean] false when there is none
    def rollback!
      return false unless @checkpoint

      restore(@checkpoint)
      @checkpoint = nil
      @offer = nil
      true
    end

    # The conversation changed outside a turn (!cmd output): rolling back
    # past that would silently drop it.
    def note_conversation_changed
      @checkpoint = nil
    end

    # A reminder turn is about to run: a pending continue offer goes, as for
    # a new prompt (the partial turn stays), so a later "no" can't roll the
    # reminder's exchange back with it.
    # @return [Boolean] whether an offer was pending
    def before_reminder_turn
      offered = awaiting_continue?
      @offer = nil
      offered
    end

    # A reminder turn ran: the rollback window closes.
    def after_reminder_turn
      @checkpoint = nil
    end

    private

    # Back to +checkpoint+, keeping the context notes that arrived since:
    # notes land between turns, after the checkpoint was taken, and a
    # rollback must not drop them. One rollback, +note+ included.
    def restore(checkpoint, note: nil)
      kept = Array(checkpoint).filter_map { |m| m[:note_id] }
      arrived = @engine.messages_checkpoint.select { |m| ContextNote.note?(m) && !kept.include?(m[:note_id]) }
      restored = Array(checkpoint) + arrived
      restored = TurnNote.replace_trailing(restored, note) if note
      @engine.rollback_to(restored)
      @restores += 1
    end

    def conversation_of(result)
      result.conversation if result.conversation.is_a?(Array)
    end

    def interrupted_turn_context(result)
      messages = interrupted_turn_messages(conversation_of(result))
      {
        original_prompt: preview_text(messages.find { |m| m[:role] == "user" }&.dig(:content), SUMMARY_PROMPT_LIMIT),
        tool_trace: tool_trace(result),
        last_model_intent: preview_text(model_intent(messages.reverse.find { |m| m[:role] == "model" }&.dig(:content)), SUMMARY_MODEL_LIMIT)
      }
    end

    # The messages the turn added after the checkpoint (all of them after an
    # empty one: a new session's first turn). The prefix is matched by role,
    # not content: the kernel returns earlier model messages without their
    # thinking, so they differ from the saved ones, one for one.
    def interrupted_turn_messages(conversation)
      checkpoint = Array(@checkpoint)
      conversation = Array(conversation)
      return [] if conversation.length < checkpoint.length
      return [] unless conversation.first(checkpoint.length).map { |m| m[:role] } == checkpoint.map { |m| m[:role] }

      conversation[checkpoint.length..] || []
    end

    def tool_trace(result)
      activities = Array(result.tool_activity)
      activities.last(SUMMARY_TOOLS_LIMIT).map do |activity|
        tool = activity[:tool].to_s.strip
        status = activity[:status].to_s.strip
        params = preview_text(activity[:params], SUMMARY_PARAMS_LIMIT)
        parts = [tool]
        parts << "status=#{status}" unless status.empty?
        parts << "params=#{params}" unless params.empty?
        parts.join(" ")
      end
    end

    def reason_message(reason)
      context = @offer && @offer[:context]
      lines = ["I chose not to continue the turn that ran out of steps because: #{reason}"]
      lines << ""
      lines << "Its work so far stays. Interrupted turn summary:"
      original_prompt = context && context[:original_prompt]
      lines << "- original_prompt: #{original_prompt.to_s.empty? ? "(unavailable)" : original_prompt}"

      tool_trace = context ? Array(context[:tool_trace]) : []
      lines << if tool_trace.empty?
                 "- interrupted_tools: (none)"
               else
                 "- interrupted_tools: #{tool_trace.join("; ")}"
               end

      model_intent = context && context[:last_model_intent]
      lines << "- last_model_intent: #{model_intent.to_s.empty? ? "(unavailable)" : model_intent}"
      lines << ""
      lines << "Please keep the original prompt context. If my next message does not provide a clear replacement request, ask what we should do instead."
      lines.join("\n")
    end

    # The model's words without its thinking and tool-call markup; when it
    # wrote nothing else, its thinking says what it was about to do.
    def model_intent(content)
      text = OutputFormatter.strip(content)
      return text unless text.empty?

      OutputFormatter.strip(content.to_s.gsub(%r{</?think>}, ""))
    end

    def preview_text(text, limit)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      return "" if normalized.empty?
      return normalized if normalized.length <= limit

      normalized[0, limit].rstrip + "..."
    end
  end
end
