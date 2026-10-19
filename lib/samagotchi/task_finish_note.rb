# frozen_string_literal: true

require "time"
require_relative "context_note"
require_relative "tool_output_cut"
require_relative "tools/task_wait"

module Samagotchi
  # The note a finished background task leaves in its session (TaskWatch,
  # the Worker's finish wake): a context note under its own header
  # (ContextNote::TASK_HEADER), as Engine#add_context_note takes it. The
  # wake variant opens a wake turn (turn_start, turn_id) and ends with the
  # ask (WAKE_TEXT); the plain one joins the next turn (queue mode, a spent
  # budget, a note-only task, the unmark after a failed wake).
  module TaskFinishNote
    WAKE_TEXT = "chi started this turn because a background task you started finished; your user didn't write " \
                "anything.\nCarry on with what you planned to do with its result. If you planned nothing, tell your " \
                "user in a sentence or two how it went."

    module_function

    # @param record [Tools::TaskRecord] the finished task
    # @param limit_sec [Integer, nil] the limit an execute handed it over at
    # @param wake [Boolean] the wake variant
    # @param cap [Integer] max_tool_output_chars: task_wait's text is cut to
    #   it as ToolRunner cuts the tool's result
    # @return [Hash] the note (ContextNote.message's keys)
    def note(record, limit_sec:, wake:, cap:, turn_id: nil, now: Time.now)
      note = { note_id: "task-#{record.id}", source: "task #{short_id(record.id)}", header: ContextNote::TASK_HEADER,
               text: text(record, limit_sec: limit_sec, wake: wake, cap: cap), created_at: now.iso8601 }
      wake ? note.merge(turn_start: true, turn_id: turn_id) : note
    end

    def text(record, limit_sec:, wake:, cap:)
      [headline(record, limit_sec), "command: #{record.command}", body(record, cap), (WAKE_TEXT if wake)].compact.join("\n")
    end

    def headline(record, limit_sec)
      seconds = duration(record)
      outcome = record.exit_code.nil? ? record.status.to_s : "exit #{record.exit_code}"
      handed = " (handed over by execute at its #{limit_sec}s limit)" if limit_sec
      "Background task #{short_id(record.id)} finished: #{outcome}#{" after #{duration_text(seconds)}" if seconds}#{handed}."
    end

    # task_wait's own text for the task, cut to +cap+ as its result would be
    # (ToolOutputCut's :head_tail_ref, naming the logs).
    def body(record, cap)
      text = Tools::TaskWait.finished_text(record).to_s
      return text if text.length <= cap

      ToolOutputCut.apply(text, cap: cap, tool: Tools::TaskWait::NAME, ref: record.output_path,
                                ref_stderr: record.stderr_path).first
    end

    # From started_at to the exit_code file's mtime (the shell's EXIT trap
    # wrote it as it ended), else finished_at: that is when a refresh first
    # noticed the end, which may be long after. nil when neither is known.
    # @return [Float, nil] seconds
    def duration(record)
      started = time(record.started_at)
      return nil unless started

      ended = exit_code_mtime(record) || time(record.finished_at)
      ended && [ended - started, 0].max
    end

    def duration_text(seconds)
      seconds = seconds.round
      return "#{seconds}s" if seconds < 60
      return format("%dm%02ds", seconds / 60, seconds % 60) if seconds < 3600

      format("%dh%02dm", seconds / 3600, (seconds % 3600) / 60)
    end

    def short_id(id) = Tools::TaskRecord.short_id(id)

    def exit_code_mtime(record)
      path = record.exit_code_path.to_s
      path.empty? || !File.file?(path) ? nil : File.mtime(path)
    rescue SystemCallError
      nil
    end

    def time(value)
      value && Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
