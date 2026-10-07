# frozen_string_literal: true

require_relative "model_profile"
require_relative "thinking_tails"

module Samagotchi
  # The one-line system note a turn leaves in the conversation when it ends
  # without an answer: failed before the model replied, cancelled, or over
  # with nothing visible. The UIs show these ends live (`turn failed …`, a
  # cancel line, `no answer: …`), but the model saw
  # none of that on its next turn: the session held an unanswered user
  # message and no reason. A tail system message, like a reminder or a
  # context note, keeps the prompt cache and is hidden by the UIs (they
  # show system messages only when `kind: note`).
  module TurnNote
    KIND = "turn_note"
    OPEN = "[SYSTEM: "
    CLOSE = "]"
    FAILED = "the previous turn failed before any answer: "
    # A failed turn whose work stayed (#failed_after): "failed after N tool
    # steps: <why>. Its work so far … stays; …".
    FAILED_AFTER = "the previous turn failed after "
    KEPT_WORK = ". Its work so far (tool calls, file changes) stays; "
    RESTORED = "The message went back to the user, who may send it again."
    TASKS_LISTED = 5
    TASK_COMMAND_CHARS = 60
    RETRY_NUDGE = :retry_nudge
    EMPTY_ANSWER = :empty_answer
    # An empty step's thinking kept on the marker: its tail, so a model
    # that thought for minutes doesn't put megabytes in the session file.
    # The same cap as ThinkingTails' saved tails.
    STEP_CHARS = ThinkingTails::TAIL_CHARS
    # A step's native thinking starts with one of these; the cut keeps it,
    # so the UIs still find the thinking (MessageParts).
    THINK_OPENS = ["<think>", ModelProfile::GEMMA_THOUGHT_CHANNEL_OPEN].freeze

    module_function

    # @param summary [String] the error's one-line summary
    # @param restored [Boolean] the prompt went back to its sender (the
    #   failed user message is not in the conversation any more)
    # @param continued [Boolean] it was a continue turn (no user message)
    # @param wake [String, nil] what woke it, when chi started the turn and
    #   not the user ("the change in attached context pr-7"): the user
    #   wrote nothing, and wakes pause until they do
    # @param kept [String, nil] what becomes of the wake's news, after
    #   that (a delegate report's rings stay for the user's next turn)
    # @param steps [Integer, nil] the turn's work stays in the conversation
    #   (LLM::FailedTurn.progress): the tool results it got to. Not with
    #   +restored+, which took the turn out.
    def failed(summary, restored: false, continued: false, wake: nil, kept: nil, steps: nil)
      return failed_after(summary, steps, continued: continued, wake: wake) if steps && !restored

      tail = if restored then RESTORED
             elsif wake
               "The wake turn for #{one_line(wake)} was not answered; chi starts no other wake turn until the user writes." +
                 (kept ? " #{one_line(kept)}" : "")
             elsif continued then "The continued turn stopped there."
             else "The user's last message was not answered."
             end
      message("#{FAILED}#{one_line(summary)}. #{tail}")
    end

    # A turn that failed partway, its work kept: "the previous turn failed
    # after 3 tool steps: <why>. Its work so far (tool calls, file changes)
    # stays; …".
    def failed_after(summary, steps, continued: false, wake: nil)
      count = "#{steps} tool step#{"s" if steps != 1}"
      tail = if wake
               "the wake turn for #{one_line(wake)} stopped there; chi starts no other wake turn until the user writes."
             elsif continued then "the continued turn stopped there."
             else
               "the user's last message is not answered yet."
             end
      message("#{FAILED_AFTER}#{count}: #{one_line(summary)}#{KEPT_WORK}#{tail}")
    end

    # The failure summary of the failed-turn note at the tail of +messages+
    # (behind context notes at most), either kind (rolled back, or its work
    # kept), or nil without one.
    def failure_summary(messages)
      list = Array(messages)
      index = trailing_index(list)
      return nil unless index

      text = (list[index][:content] || list[index]["content"]).to_s
      if text.start_with?("#{OPEN}#{FAILED}")
        text["#{OPEN}#{FAILED}".length..].sub(/\. [^.]*\.\]\z/, "")
      elsif text.start_with?("#{OPEN}#{FAILED_AFTER}") && text.include?(KEPT_WORK)
        text[0...text.rindex(KEPT_WORK)].sub(/\A#{Regexp.escape(OPEN + FAILED_AFTER)}\d+ tool steps?: /, "")
      end
    end

    # @param reason [Symbol, String, nil] the cancel reason (:ctrl_c, :user…)
    # @param seconds [Numeric, nil] how long the turn had run
    # @param shown [Boolean] visible text had streamed (an `[interrupted]`
    #   model message precedes this note): an answer, or only narration
    #   before a tool call, so the note says "reply"
    # @param running_tasks [Array<Hash>] {id:, command:} of this session's
    #   background tasks still running: a Stop doesn't end them
    # @param stopped_by [Hash, nil] {by:, reason:} of a hook that stopped
    #   it (stop_turn, or a cut with no retry left)
    def cancelled(reason, seconds: nil, shown: false, running_tasks: [], stopped_by: nil)
      why = reason.to_s.empty? ? "" : " (#{reason.to_s.tr("_", "-")}#{stopper(stopped_by)})"
      after = seconds ? " after #{seconds.round}s" : ""
      what = shown ? "the reply above ends where it was cut off." : "no answer had been shown."
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

    # The model reads the text only. The marker (EMPTY_ANSWER) is for the
    # UIs, which draw the turn's notice and steps from it after a reload:
    # +retries+ the empty-answer retries spent, +steps+ the empty
    # generations as model messages (their thinking; the loops keep them out
    # of the conversation, where they'd be empty assistant turns), each
    # text cut to its last STEP_CHARS. Never
    # sent: the payload builders send a system message's content, and the
    # copies for hooks, plugins and the recap drop it (AnswerDisplay.strip).
    def empty(retries: 0, steps: [])
      marker = { retries: retries.to_i }
      marker[:steps] = steps.map { |step| capped_step(step) } unless steps.empty?
      message("the previous turn ended with no visible answer (thinking only, or nothing). The user's last message is still unanswered.")
        .merge(EMPTY_ANSWER => marker)
    end

    def capped_step(step)
      step.slice(:role, :content, :thinking).to_h do |key, value|
        [key, key == :role || !value.is_a?(String) ? value : tail_of(value)]
      end
    end

    # The last STEP_CHARS of +text+ after a line saying how much was cut
    # (and the thinking's opening tag when it had one); short text as is.
    def tail_of(text)
      return text if text.length <= STEP_CHARS

      open = THINK_OPENS.find { |tag| text.start_with?(tag) }
      "#{open}[… #{text.length - STEP_CHARS} earlier characters cut]\n#{text[-STEP_CHARS..]}"
    end

    # The empty-answer marker of +entry+ (either key type), or nil.
    def empty_answer(entry)
      return nil unless note?(entry)

      marker = entry[EMPTY_ANSWER] || entry[EMPTY_ANSWER.to_s]
      marker.is_a?(Hash) ? marker : nil
    end

    # The notice every UI shows for a turn that ended with no answer:
    # "no answer: the model returned nothing (after 1 retry)" (turn_events.js
    # emptyAnswerLine words it the same).
    def empty_answer_line(retries)
      count = retries.to_i
      after = if count.positive?
                " (after #{count} #{count == 1 ? "retry" : "retries"})"
              else
                ""
              end
      "no answer: the model returned nothing#{after}"
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
                          "again; continue the task with your next tool call, or answer if it is done."))
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

    # The step-limit offer answered Stop (no reason): the partial turn
    # stays, and the model reads that it wasn't continued.
    def not_continued
      message("the previous turn ran out of steps before it answered, and the user chose not to continue it. " \
              "Its work so far (tool calls, file changes) stays; wait for the user's next message.")
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

    # A copy of +messages+ without the note at its tail when that note is a
    # retry nudge (anything else stays: an earlier turn's note is what says
    # why that turn ended).
    def without_trailing_nudge(messages)
      list = Array(messages).dup
      index = trailing_index(list)
      list.delete_at(index) if index && retry_nudge?(list[index])
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
