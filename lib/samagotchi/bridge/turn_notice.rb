# frozen_string_literal: true

module Samagotchi
  class Bridge
    # The events a running turn shows as rows of its own (not text, thinking
    # or a tool call): a hook's notice, the loop asking again after an empty
    # or cut answer, a question and how it was answered. A UI that joins the
    # turn mid-way (TurnAccumulator's "notice" part) and one that reloads a
    # finished turn (CardStore) get the event back with the fields listed
    # here, and draw it with the handler that drew it live, where it was.
    module TurnNotice
      FIELDS = {
        hook_notice: %i[hook text level],
        empty_answer_retry: %i[iteration attempt of stopped_by malformed],
        steer_cut: %i[iteration source],
        question_requested: %i[pending_question],
        question_answered: %i[id answer],
        question_cancelled: %i[id reason]
      }.freeze

      module_function

      # @return [Boolean] whether +event+ is one of a turn's rows
      def notice?(event)
        FIELDS.key?(event[:type])
      end

      # The event as a UI replays it: its type (a String, as JSON has it)
      # and the fields it had, deep-copied.
      # @return [Hash]
      def slice(event)
        fields = event.slice(*FIELDS.fetch(event[:type]))
        copy = Marshal.load(Marshal.dump(fields))
        { type: event[:type].to_s, **copy }
      end
    end
  end
end
