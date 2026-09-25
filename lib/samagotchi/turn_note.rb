# frozen_string_literal: true

module Samagotchi
  # The one-line system note a turn leaves in the conversation when it ends
  # without an answer: failed before the model replied, cancelled, or over
  # with nothing visible. The UIs show these ends live (`turn failed …`, a
  # cancel line, `(the model returned an empty answer)`), but the model saw
  # none of that on its next turn: the session held an unanswered user
  # message and no reason. A tail system message, like a reminder or a
  # context note, keeps the prompt cache and is hidden by the UIs (they
  # show system messages only when `kind: note`).
  module TurnNote
    KIND = "turn_note"
    OPEN = "[SYSTEM: "
    CLOSE = "]"

    module_function

    # @param summary [String] the error's one-line summary
    # @param restored [Boolean] the prompt went back to its sender (the
    #   failed user message is not in the conversation any more)
    # @param continued [Boolean] it was a continue turn (no user message)
    def failed(summary, restored: false, continued: false)
      tail = if restored then "The message went back to the user, who may send it again."
             elsif continued then "The continued turn stopped there."
             else "The user's last message was not answered."
             end
      message("the previous turn failed before any answer: #{one_line(summary)}. #{tail}")
    end

    # @param reason [Symbol, String, nil] the cancel reason (:ctrl_c, :user…)
    # @param seconds [Numeric, nil] how long the turn had run
    # @param shown [Boolean] visible text had streamed (an `[interrupted]`
    #   model message precedes this note)
    def cancelled(reason, seconds: nil, shown: false)
      why = reason.to_s.empty? ? "" : " (#{reason.to_s.tr("_", "-")})"
      after = seconds ? " after #{seconds.round}s" : ""
      what = shown ? "the answer above ends where it was cut off." : "no answer had been shown."
      message("the previous turn was cancelled#{why}#{after}; #{what}")
    end

    def empty
      message("the previous turn ended with no visible answer (thinking only, or nothing). The user's last message is still unanswered.")
    end

    def note?(entry)
      return false unless entry.respond_to?(:[])

      (entry[:kind] || entry["kind"]).to_s == KIND
    end

    def message(text)
      { role: "system", content: "#{OPEN}#{text}#{CLOSE}", kind: KIND }
    end

    # +messages+ plus +note+, in place of a note already at the tail (behind
    # context notes at most): failed retries leave one note, not a pile.
    def replace_trailing(messages, note)
      list = Array(messages).dup
      index = list.length - 1
      index -= 1 while index >= 0 && (list[index][:role] || list[index]["role"]).to_s == "system" && !note?(list[index])
      list.delete_at(index) if index >= 0 && note?(list[index])
      list << note
    end

    # The last message is a reply cut short (`[interrupted]`).
    def interrupted_tail?(messages)
      last = Array(messages).last
      !!(last && (last[:interrupted] || last["interrupted"]))
    end

    def one_line(text)
      text.to_s.gsub(/\s+/, " ").strip
    end
  end
end
