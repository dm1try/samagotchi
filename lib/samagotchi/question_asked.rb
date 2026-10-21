# frozen_string_literal: true

require_relative "answer_refs"
require_relative "log"
require_relative "output_formatter"

module Samagotchi
  # The :question_asked hook event: a question of the model's own (its
  # ask_user_question, kind "question") or an approval of its tool call
  # (kind "approval") is about to open. Fired from the two Engine seams
  # (Engine#request_question, the guardrail wiring's ask:), never from
  # QuestionDesk, so a relayed delegate approval, a hook's ask_user and the
  # step-limit question never fire it.
  #
  # A hook attaches refs to the reply that asks (event[:refs], after_turn's
  # call shape and checks, AnswerRefs): they are kept as `display_refs` on
  # the step's model message (the live conversation's last model entry,
  # changed in place: the loops and the forget layer hold it by identity),
  # display only, and go on the pending question (PendingQuestion#refs), so
  # a UI pairs them in the asking text, on the card and in the history.
  #
  # The hooks run on the turn thread before the question opens: their time
  # is the question's wait. A raising hook is logged (Registry#fire) and the
  # question opens without its refs; event[:ask_user] is a no-op (nil).
  module QuestionAsked
    EVENT = :question_asked
    KIND_QUESTION = "question"
    KIND_APPROVAL = "approval"
    # Lower than an answer's (AnswerRefs): cards.json holds up to 20 cards.
    MAX_REFS = 50
    MAX_BYTES = 32 * 1024

    module_function

    # Fire the event and return the question's fields with the step's refs
    # (+fields+ as given when it has none, or with no subscriber: then
    # nothing is built).
    # @param hooks [Hooks::Registry]
    # @param conversation [Array<Hash>, nil] the running turn's live
    #   conversation (Engine#live_conversation)
    # @param kind [String] KIND_QUESTION or KIND_APPROVAL
    # @param fields [Hash] the question's fields (no id yet)
    # @param cwd [String, nil] the session's folder, for file refs
    # @param synchronize [#call, nil] runs the step's change under the
    #   event lock (a snapshot reads the conversation under it)
    # @param visible [#call, nil] (content) → the step's text as the asking
    #   slot shows it; default OutputFormatter.strip_markup (the Engine's
    #   drops the native loop's tool-call bodies first)
    # @return [Hash] the fields to open the question with
    def fire(hooks:, conversation:, kind:, fields:, cwd:, synchronize: nil, visible: nil)
      return fields unless hooks&.any?(EVENT)

      step = Array(conversation).reverse_each.find { |m| m.is_a?(Hash) && (m[:role] || m["role"]).to_s == "model" }
      refs = AnswerRefs.new(step ? [step] : [], cwd: cwd, max_refs: MAX_REFS, max_bytes: MAX_BYTES)
      visible ||= ->(content) { OutputFormatter.strip_markup(content) }
      event = { type: EVENT, kind: kind, text: step ? visible.call((step[:content] || step["content"]).to_s) : "",
                question: deep_freeze(Marshal.load(Marshal.dump(fields.to_h))),
                # A question from here would wait inside the one opening.
                ask_user: ->(**) {} }
      event[:refs] = refs.adder(event)
      hooks.fire(EVENT, event)
      refs.close!
      list = refs.to_a
      if refs.added?
        store = -> { step[AnswerRefs::KEY] = list }
        synchronize ? synchronize.call(&store) : store.call
      end
      # The step's whole list: a second question in it gets the first's too.
      list.empty? ? fields : fields.merge(refs: list)
    rescue StandardError => e
      Log.warn(:hooks, "question_asked_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      fields
    end

    def deep_freeze(value)
      case value
      when Hash then value.each_value { |v| deep_freeze(v) }
      when Array then value.each { |v| deep_freeze(v) }
      end
      value.freeze
    end
  end
end
