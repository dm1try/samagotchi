# frozen_string_literal: true

require_relative "config"
require_relative "turn_note"

module Samagotchi
  # SPIKE (turn.done_check): once per turn, the first text-only answer of a
  # turn that ran a file-changing tool is not taken at once. The answer stays,
  # a hidden note (TurnNote.done_check) asks the model to re-read the task and
  # finish a step it skipped, and it generates again:
  # - DONE (or an empty reply, or a short line with DONE): the saved answer
  #   stands, the note goes;
  # - tool calls: the turn goes on (the note stays in the history), and the
  #   next text-only answer ends it as usual;
  # - another full text: it replaces the first answer (the note goes too).
  # Small models end a coding task with a full report but no commit (the
  # harness-eval no-commit runs); this asks them once before the turn ends.
  # execute doesn't count as a change: most execute-only turns only look
  # (ls, grep, specs), and a task that asks for a commit also edits files.
  class DoneCheck
    MODES = %w[off edits].freeze
    FILE_TOOLS = %w[edit write].freeze
    # A reply this short that says DONE is a "done", not a new answer.
    DONE_CHARS = 200

    def self.mode
      value = Config.get("turn.done_check").to_s
      MODES.include?(value) ? value : "off"
    rescue StandardError
      "off"
    end

    # The check's reply means "all done": empty, short and saying DONE, or
    # ending on a DONE line (a checklist of what was done, then DONE: the
    # first answer, the full report, stays).
    def self.done_reply?(text)
      text = text.to_s.strip
      return true if text.empty? || (text.length <= DONE_CHARS && text.match?(/\bDONE\b/))

      text.lines.last.to_s.strip.match?(/\A\W*DONE\W*\z/)
    end

    def initialize(mode: self.class.mode)
      @mode = mode
      @edited = false
      @state = :idle
      @answer = nil
    end

    # The names of the tools a step called.
    def saw_calls(names)
      @edited ||= Array(names).any? { |name| FILE_TOOLS.include?(name.to_s) }
    end

    # The answer just kept is checked: on, not done this turn, files changed.
    def fire?
      @mode == "edits" && @state == :idle && @edited
    end

    # The check's generation is next.
    def pending? = @state == :pending

    # The answer (the conversation's last entry) is saved, the note goes on.
    def ask!(conversation, emit:, iteration:)
      @state = :pending
      @answer = conversation.last
      conversation << TurnNote.done_check
      emit.call({ type: :done_check, iteration: iteration, outcome: "asked",
                  answer_chars: @answer[:content].to_s.length })
    end

    # The check's generation returned: :tools (the turn goes on), :done
    # (the saved answer's text is returned and the note leaves) or
    # :replaced (+text+ is the answer; the first one and the note leave;
    # the caller appends the new answer). Returns [outcome, answer text].
    def resolve!(conversation, text, tool_calls:, emit:, iteration:)
      @state = :spent
      outcome = if tool_calls then "tools"
                elsif self.class.done_reply?(text) then "done"
                else "replaced"
                end
      emit.call({ type: :done_check, iteration: iteration, outcome: outcome, reply_chars: text.to_s.length })
      return [:tools, nil] if outcome == "tools"

      remove_note(conversation)
      return [:done, @answer[:content].to_s] if outcome == "done"

      index = conversation.rindex { |entry| entry.equal?(@answer) }
      conversation.delete_at(index) if index
      [:replaced, text]
    end

    # A cancel while the check runs: the note goes, the answer stays.
    def abandon!(conversation)
      remove_note(conversation) if pending?
      @state = :spent
    end

    private

    def remove_note(conversation)
      index = conversation.rindex { |entry| TurnNote.done_check?(entry) }
      conversation.delete_at(index) if index
    end
  end
end
