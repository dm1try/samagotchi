# frozen_string_literal: true

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
      return [:resume, nil] if lowered == CONTINUE_COMMAND || lowered == "yes" || lowered == "y"
      return [:abort, nil] if lowered == "no" || lowered == "n"

      reason_match = normalized.match(/\A(?:no|n)\s*[,:\-]\s*(.+)\z/i)
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

    def initialize(engine:)
      @engine = engine
      @checkpoint = nil
      @continue_checkpoint = nil
      @offer = nil
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
      if result.respond_to?(:canceled?) && result.canceled?
        if continue
          @engine.rollback_to(@continue_checkpoint)
          return :continue_cancelled
        end

        # The kernel salvaged the completed tool calls and the partial reply
        # into the conversation; without one, the turn leaves nothing.
        @engine.rollback_to(@checkpoint) if @checkpoint && !conversation_of(result)
        @offer = nil
        return :cancelled
      end

      if result.respond_to?(:resumable?) && result.resumable?
        @offer = { context: interrupted_turn_context(result), no_interrupt: no_interrupt }
        :continue_offered
      else
        @offer = nil
        @checkpoint = nil
        :completed
      end
    end

    # A prompt turn failed: back to the conversation before it.
    def prompt_turn_failed
      @engine.rollback_to(@checkpoint) if @checkpoint
      @offer = nil
      @checkpoint = nil
    end

    # Answer the offer with no: the interrupted turn is discarded, and a
    # reason (with a summary of that turn) is left for the model to read.
    def abort_continue!(reason: nil)
      @engine.rollback_to(@checkpoint) if @checkpoint
      @checkpoint = nil
      @engine.append_messages([{ role: "user", content: reason_message(reason) }]) if reason
      @offer = nil
    end

    # A new prompt came instead of an answer (a worker takes it): the offer
    # is gone and the partial turn stays, as after a Ctrl-C.
    def drop_offer!
      @offer = nil
    end

    # Restore the pre-turn checkpoint (!rollback after a Ctrl-C).
    # @return [Boolean] false when there is none
    def rollback!
      return false unless @checkpoint

      @engine.rollback_to(@checkpoint)
      @checkpoint = nil
      true
    end

    # The conversation changed outside a turn (!cmd output): rolling back
    # past that would silently drop it.
    def note_conversation_changed
      @checkpoint = nil
    end

    # A reminder turn ran. The checkpoint stays only for a pending offer.
    def after_reminder_turn
      @checkpoint = nil unless awaiting_continue?
    end

    private

    def conversation_of(result)
      result.conversation if result.respond_to?(:conversation) && result.conversation.is_a?(Array)
    end

    def interrupted_turn_context(result)
      messages = interrupted_turn_messages(conversation_of(result))
      {
        original_prompt: preview_text(messages.find { |m| m[:role] == "user" }&.dig(:content), SUMMARY_PROMPT_LIMIT),
        tool_trace: tool_trace(result),
        last_model_intent: preview_text(messages.reverse.find { |m| m[:role] == "model" }&.dig(:content), SUMMARY_MODEL_LIMIT)
      }
    end

    # The messages the turn added after the checkpoint (all of them after an
    # empty one: a new session's first turn).
    def interrupted_turn_messages(conversation)
      checkpoint = Array(@checkpoint)
      conversation = Array(conversation)
      return [] if conversation.length < checkpoint.length
      return [] unless conversation.first(checkpoint.length) == checkpoint

      conversation[checkpoint.length..] || []
    end

    def tool_trace(result)
      activities = result.respond_to?(:tool_activity) ? Array(result.tool_activity) : []
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
      lines = ["I chose not to continue the interrupted turn because: #{reason}"]
      lines << ""
      lines << "Interrupted turn summary:"
      original_prompt = context && context[:original_prompt]
      lines << "- original_prompt: #{original_prompt.to_s.empty? ? "(unavailable)" : original_prompt}"

      tool_trace = context ? Array(context[:tool_trace]) : []
      if tool_trace.empty?
        lines << "- interrupted_tools: (none)"
      else
        lines << "- interrupted_tools: #{tool_trace.join("; ")}"
      end

      model_intent = context && context[:last_model_intent]
      lines << "- last_model_intent: #{model_intent.to_s.empty? ? "(unavailable)" : model_intent}"
      lines << ""
      lines << "Please keep the original prompt context. If my next message does not provide a clear replacement request, ask what we should do instead."
      lines.join("\n")
    end

    def preview_text(text, limit)
      normalized = text.to_s.gsub(/\s+/, " ").strip
      return "" if normalized.empty?
      return normalized if normalized.length <= limit

      normalized[0, limit].rstrip + "..."
    end
  end
end
