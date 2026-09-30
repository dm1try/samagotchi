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
    FAILED = "the previous turn failed before any answer: "
    RESTORED = "The message went back to the user, who may send it again."
    TASKS_LISTED = 5
    TASK_COMMAND_CHARS = 60
    RETRY_NUDGE = :retry_nudge

    module_function

    # @param summary [String] the error's one-line summary
    # @param restored [Boolean] the prompt went back to its sender (the
    #   failed user message is not in the conversation any more)
    # @param continued [Boolean] it was a continue turn (no user message)
    def failed(summary, restored: false, continued: false)
      tail = if restored then RESTORED
             elsif continued then "The continued turn stopped there."
             else "The user's last message was not answered."
             end
      message("#{FAILED}#{one_line(summary)}. #{tail}")
    end

    # @param reason [Symbol, String, nil] the cancel reason (:ctrl_c, :user…)
    # @param seconds [Numeric, nil] how long the turn had run
    # @param shown [Boolean] visible text had streamed (an `[interrupted]`
    #   model message precedes this note)
    # @param running_tasks [Array<Hash>] {id:, command:} of this session's
    #   background tasks still running: a Stop doesn't end them
    # @param stopped_by [Hash, nil] {by:, reason:} of a hook that stopped
    #   it (stop_turn, or a cut with no retry left)
    def cancelled(reason, seconds: nil, shown: false, running_tasks: [], stopped_by: nil)
      why = reason.to_s.empty? ? "" : " (#{reason.to_s.tr("_", "-")}#{stopper(stopped_by)})"
      after = seconds ? " after #{seconds.round}s" : ""
      what = shown ? "the answer above ends where it was cut off." : "no answer had been shown."
      message("the previous turn was cancelled#{why}#{after}; #{what}#{still_running(running_tasks)}")
    end

    # " <by>: <reason>" of a hook that stopped the turn, as far as known.
    def stopper(stopped_by)
      return "" unless stopped_by.is_a?(Hash)

      by = one_line(stopped_by[:by])
      reason = one_line(stopped_by[:reason])
      [by.empty? ? nil : " #{by}", reason.empty? ? nil : ": #{reason}"].compact.join
    end

    def still_running(tasks)
      return "" if tasks.empty?

      listed = tasks.first(TASKS_LISTED).map do |task|
        command = one_line(task[:command])
        command = "#{command[0, TASK_COMMAND_CHARS - 1]}…" if command.length > TASK_COMMAND_CHARS
        "task #{task[:id]} (#{command})"
      end
      listed << "#{tasks.size - TASKS_LISTED} more (task_list)" if tasks.size > TASKS_LISTED
      " Still running: #{listed.join(", ")}. Continue with task_wait <id> or stop with task_stop <id>."
    end

    def empty
      message("the previous turn ended with no visible answer (thinking only, or nothing). The user's last message is still unanswered.")
    end

    # The hidden nudge before a retry of an empty answer (EmptyAnswerRetry):
    # the model never sees its empty generation, so it is told what happened.
    def empty_retry
      retry_nudge(message("your last reply had no visible answer. Answer the user's last message now, briefly."))
    end

    # The hidden nudge before a retry of a generation a plugin cut
    # (stop_generation): +by+ is the bundle, +reason+ what it said.
    def cut_retry(by, reason)
      why = reason.to_s.strip.empty? ? "" : ": #{one_line(reason)}"
      retry_nudge(message("your last reply was cut off by #{by || "a plugin"}#{why}. Don't start the same reasoning " \
                          "again; answer the user's last message now, briefly."))
    end

    # A retry nudge is marked, so the spent one is found by the mark
    # whatever its words (KernelLoop drops it when the retry fails too).
    def retry_nudge(note)
      note.merge(RETRY_NUDGE => true)
    end

    def retry_nudge?(entry)
      entry.respond_to?(:[]) && (entry[RETRY_NUDGE] || entry[RETRY_NUDGE.to_s]) == true
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
      without_trailing(messages) << note
    end

    # A copy of +messages+ without the note at its tail (behind context
    # notes at most).
    def without_trailing(messages)
      list = Array(messages).dup
      index = trailing_index(list)
      list.delete_at(index) if index
      list
    end

    # The index of the note at the tail of +list+ (behind context notes at
    # most), or nil.
    def trailing_index(list)
      index = list.length - 1
      index -= 1 while index >= 0 && (list[index][:role] || list[index]["role"]).to_s == "system" && !note?(list[index])
      index >= 0 && note?(list[index]) ? index : nil
    end

    # The failure summary of the note at the tail of +messages+ (behind
    # context notes at most) when it says a failed turn's prompt went back
    # to the user, else nil: the prompt is not in the conversation any more
    # (the session's last_prompt holds it), so a UI shows it from here.
    def restored_failure(messages)
      list = Array(messages)
      index = trailing_index(list)
      return nil unless index

      text = (list[index][:content] || list[index]["content"]).to_s
      prefix = "#{OPEN}#{FAILED}"
      suffix = ". #{RESTORED}#{CLOSE}"
      return nil unless text.start_with?(prefix) && text.end_with?(suffix)

      text[prefix.length...-suffix.length]
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
