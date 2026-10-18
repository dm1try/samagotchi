# frozen_string_literal: true

module Samagotchi
  # The one open question of a session (QuestionDesk's pending question,
  # Session#pending_question): the model's ask_user_question, a hook's
  # ask_user, a guardrail approval, a relayed delegate approval or the
  # step-limit question (kind "continue").
  #
  # id: the question's uuid; question, options, header, multi_select,
  # allow_freeform: what the UIs show; effects: each option's effect for
  # a parent agent's answer, in option order (Guardrails::ParentPolicy;
  # nil: untagged); user_only: only the user may pick an option that isn't
  # a deny or a plain answer (an approval on chi's own config); kind: nil
  # for the model's own, "hook", "approval" or "continue"; hook: the asking
  # hook's name;
  # approval: the approval's facts (Guardrails::Approval.payload); relay: a
  # relayed approval's facts (Relay.card); limit, context: the step-limit
  # question's turn limit and offer context (ContinueOffer); status:
  # "pending" or "cancelled"; created_at: iso8601; relayed_to: the relay
  # mark ({parent_id:, parent_short:, relay_id:}, QuestionDesk#annotate).
  # approval, relay, context and relayed_to stay Hashes as given (string
  # keys inside after a load). A field may be nil (unset).
  #
  # Crosses the process as a Hash: #to_h for an event, a Bridge snapshot or
  # a UI (symbol keys), #to_file for session.json (string keys); both in
  # member order with unset fields left out. .from_file reads either back.
  PendingQuestion = Data.define(:id, :question, :options, :header, :multi_select, :allow_freeform, :effects, :user_only,
                                :kind, :hook, :approval, :relay, :limit, :context, :status, :created_at, :relayed_to) do
    def initialize(**fields)
      super(**members.to_h { |m| [m, nil] }, **fields)
    end

    # A saved or sent record (string or symbol keys, a key we don't know
    # dropped), a PendingQuestion as it is; nil for anything else.
    # @return [PendingQuestion, nil]
    def self.from_file(raw)
      return raw if raw.is_a?(PendingQuestion)
      return nil unless raw.is_a?(Hash)

      new(**members.to_h { |m| [m, raw.key?(m.to_s) ? raw[m.to_s] : raw[m]] })
    end

    # The event / snapshot shape: symbol keys, in member order, unset
    # fields left out.
    # @return [Hash{Symbol => Object}]
    def to_h = super.compact

    # The session file's record: string keys, in member order, unset
    # fields left out.
    # @return [Hash{String => Object}]
    def to_file = to_h.transform_keys(&:to_s)
  end
end
