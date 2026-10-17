# frozen_string_literal: true

module Samagotchi
  # An answer to the pending question (QuestionDesk#answer's value, what
  # Engine#answer_question returns): id: the question's id; selected: the
  # chosen option labels; freeform: the typed text or nil; selected_indices:
  # the chosen options' positions; by: "parent_agent" for a parent agent's
  # answer, else nil.
  #
  # Crosses a process or a bundle as a Hash (#to_h, symbol keys): the
  # :question_answered event, the Bridge's and RelayVerifier's JSON
  # responses, the ask_user_question tool result and the hook/plugin
  # ask_user result (built field by field in QuestionDesk#ask_for_hook).
  # JSON.generate of a Data value writes its inspect string, so every JSON
  # boundary calls #to_h first.
  QuestionAnswer = Data.define(:id, :selected, :freeform, :selected_indices, :by) do
    def initialize(id:, selected:, freeform: nil, selected_indices: [], by: nil)
      super
    end

    # Whether a parent agent gave it (not the user).
    def parent_agent? = by == "parent_agent"

    # The event / JSON shape: symbol keys in member order; +by+ left out
    # when nil, every other key kept even when nil.
    # @return [Hash{Symbol => Object}]
    def to_h = super.tap { |h| h.delete(:by) if h[:by].nil? }
  end
end
