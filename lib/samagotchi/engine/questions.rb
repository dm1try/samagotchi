# frozen_string_literal: true

require_relative "../output_formatter"
require_relative "../question_asked"

module Samagotchi
  class Engine
    # Ask-user-question: the model's question (its :question_asked hooks),
    # and opening, posting, answering and cancelling questions
    # (QuestionDesk, forwarded). Reads @question_desk, @hooks, @kernel,
    # @session.
    module QuestionsPart
      # ── Ask-user-question (structured qualification) ──────────────────────────

      # @return [PendingQuestion, nil] the question pending now
      def pending_question
        @question_desk.pending
      end

      # Ask the model's question (ask_user_question): the kernel's
      # Services#question_handler, called on the turn thread with the payload
      # Tools::AskUserQuestion.validate made (QuestionDesk#request), after
      # the :question_asked hooks (QuestionAsked) gave the step its refs; a
      # --non-interactive run has no one to ask, so they don't fire there.
      # @param payload [Hash] {question:, options:, header:, multi_select:, allow_freeform:}
      # @return [String] normalized answer JSON
      def request_question(payload)
        payload = question_asked(QuestionAsked::KIND_QUESTION, payload) unless interface == :non_interactive
        @question_desk.request(payload)
      end

      # The :question_asked hooks for a question of the model's about to
      # open: the fields with the asking step's refs (QuestionAsked.fire).
      # @return [Hash]
      def question_asked(kind, fields)
        QuestionAsked.fire(hooks: @hooks, conversation: live_conversation, kind: kind, fields: fields,
                           cwd: @session&.working_directory, synchronize: ->(&block) { synchronize_events(&block) },
                           visible: ->(content) { question_step_text(content) })
      end
      private :question_asked

      # A step's text as the asking slot shows it: the native loop's raw
      # response without its thoughts and tool-call bodies (a chat step has
      # neither), then the markup's tokens (OutputFormatter.strip_markup).
      def question_step_text(content)
        parser = @kernel.parser
        OutputFormatter.strip_markup(parser.strip_tool_calls(parser.strip_thought(content)))
      end
      private :question_step_text

      # Open a question for the UIs and wait for its answer
      # (QuestionDesk#open_question: BLOCKS until answered or cancelled).
      # @param fields [Hash] question:, options:, header:, multi_select:, allow_freeform:, …
      #   (as a Hash or as keywords)
      # @param watch [#call, nil] closes the question with the reason it returns
      # @return [QuestionAnswer, Hash, String] the answer, or {error:, …}, or a
      #   sync handler's text
      def open_question(fields = nil, watch: nil, **more)
        @question_desk.open_question({ **fields.to_h, **more }, watch: watch)
      end

      # Publish a standing question that blocks nobody (QuestionDesk#post: a
      # worker's step-limit question).
      # @return [PendingQuestion, nil] the pending question, nil while another is open
      def post_question(fields, on_answer:, on_superseded_close: nil)
        @question_desk.post(fields, on_answer: on_answer, on_superseded_close: on_superseded_close)
      end

      # Withdraw the standing question (QuestionDesk#withdraw).
      # @return [Boolean]
      def withdraw_question(reason, id: nil)
        @question_desk.withdraw(reason, id: id)
      end

      # Answer the pending question (called from UI thread; QuestionDesk#answer).
      # @return [QuestionAnswer]
      def answer_question(id:, selected:, freeform: nil, client_id: nil, parent_agent: nil)
        @question_desk.answer(id: id, selected: selected, freeform: freeform, client_id: client_id,
                              parent_agent: parent_agent)
      end

      # Mark the pending question as relayed, or clear the mark
      # (QuestionDesk#annotate).
      # @return [Boolean]
      def annotate_question(id, relayed_to:, reason: nil)
        @question_desk.annotate(id, relayed_to: relayed_to, reason: reason)
      end

      def set_question_sync_handler(&block)
        @question_desk.sync_handler = block
      end

      # Cancel the pending question (QuestionDesk#cancel).
      # @return [Boolean] whether it was cancelled
      # @raise [QuestionDesk::NotDismissable] +id+ names a standing question
      def cancel_question(reason = "user", id: nil)
        @question_desk.cancel(reason, id: id)
      end
    end
  end
end
