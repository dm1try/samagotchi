# frozen_string_literal: true

require_relative "session"
require_relative "bridge_client"
require_relative "worker_sidecar"
require_relative "question_desk"
require_relative "guardrails/parent_approvals"
require_relative "log"

module Samagotchi
  # A child worker taking its parent's answer to a relayed approval. The
  # POST that says "answered" carries no answer and no authority: this
  # worker asks its parent session's live Bridge what the parent's relay
  # holds (RelayDesk, which only the parent's question flow writes), and
  # answers its own question with that, only when it is about this session
  # and the question pending now, and is answered.
  class RelayVerifier
    # The client id a relayed answer is recorded with: relay:<parent8>.
    CLIENT_PREFIX = "relay"

    # @param engine [Engine] this (the child's) worker's Engine
    def initialize(engine:, state_dir:, session_id:)
      @engine = engine
      @state_dir = state_dir
      @session_id = session_id
    end

    # @return [Array(Hash, Integer, Hash)] headers, status, body: 200
    #   answered, 409 no longer pending, 403 refused (a parent agent's allow
    #   beyond this worker's guardrails.parent_approvals), 422
    #   relay_unverified (logged; the question stays open)
    def answer(relay_id:, question_id:)
      parent_id = own_parent_id or return unverified("this session has no parent", relay_id)
      relay = parent_relay(parent_id, relay_id) or return unverified("the parent has no such relay", relay_id)
      return unverified("the relay is about another session", relay_id) unless relay["child_id"] == @session_id
      return unverified("the relay is about another question", relay_id) unless relay["child_question_id"] == question_id
      return unverified("the relay is #{relay["state"]}, not answered", relay_id) unless relay["state"] == "answered"

      apply(relay, parent_id: parent_id, question_id: question_id, relay_id: relay_id)
    end

    private

    def apply(relay, parent_id:, question_id:, relay_id:)
      answer = relay["answer"].is_a?(Hash) ? relay["answer"] : {}
      parent_agent = relay["by"] != "user"
      client_id = "#{CLIENT_PREFIX}:#{parent_id[0, 8]}"
      if answer["dismissed"]
        return not_pending(question_id) unless @engine.cancel_question("dismissed", id: question_id)

        log("relay_answered", relay_id, id: question_id, dismissed: true, by: relay["by"])
        return [{}, 200, { status: "dismissed", question_id: question_id }]
      end

      selected = labels(answer["selected_indices"], question_id) or return unverified("the answer's option is out of range", relay_id)
      result = @engine.answer_question(id: question_id, selected: selected, freeform: answer["freeform"],
                                       client_id: client_id, parent_agent: parent_agent)
      log("relay_answered", relay_id, id: question_id, by: relay["by"])
      [{}, 200, { status: "answered", question_id: question_id, answer: result }]
    rescue QuestionDesk::NotPending
      not_pending(question_id)
    rescue QuestionDesk::Refused => e
      log("relay_refused", relay_id, id: question_id, reason: e.reason)
      [{}, 403, { error: "parent_approval_refused", reason: e.reason.to_s,
                  detail: Guardrails::ParentApprovals.message(e.reason) }]
    rescue ArgumentError => e
      unverified("the answer doesn't fit the question: #{e.message}", relay_id)
    end

    # The parent's option indices as this question's own labels (the
    # parent's are relabelled; the order is the same). nil when one is out
    # of range; [] for a freeform-only deny.
    def labels(indices, question_id)
      pending = @engine.pending_question
      return [] unless pending && pending[:id].to_s == question_id

      options = Array(pending[:options])
      indices = Array(indices)
      return nil unless indices.all? { |index| index.is_a?(Integer) && index >= 0 && index < options.size }

      indices.map { |index| options[index] }
    end

    def own_parent_id
      Session.load(@session_id, state_dir: @state_dir).parent_id
    rescue ArgumentError
      nil
    end

    # @return [Hash, nil] what the parent's live Bridge says about the relay
    def parent_relay(parent_id, relay_id)
      dir = Session.session_dir(parent_id, state_dir: @state_dir)
      client = BridgeClient.discover(parent_id, session_dir: dir) or return nil
      response = client.relay_status(relay_id)
      response.ok? ? response.json : nil
    rescue SystemCallError, IOError
      nil
    end

    def not_pending(question_id)
      [{}, 409, { error: "question_not_pending", detail: "no pending question #{question_id}" }]
    end

    def unverified(why, relay_id)
      log("relay_unverified", relay_id, why: why)
      [{}, 422, { error: "relay_unverified", detail: why }]
    end

    def log(event, relay_id, **fields)
      Log.info(:bridge, event, sid: @session_id, relay: relay_id.to_s[0, 8], **fields)
    end
  end
end
