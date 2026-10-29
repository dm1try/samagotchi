# frozen_string_literal: true

require_relative "task_runtime"
require_relative "ref_text"

module Samagotchi
  module Tools
    class TaskWait
      NAME = "task_wait"
      TIMEOUT_DEFAULT = 600
      TAIL_LINES_DEFAULT = 10
      TAIL_LINES_MAX = 100
      POLL_INTERVAL = 0.5
      # A handed-over execute keeps stderr in a log of its own: at most this
      # many of its last lines follow the output tail.
      STDERR_TAIL_LINES_MAX = 10
      # The note of a wait a waiting message ended (wait_result:
      # message_waiting); %<id>s is the task's id. "The user" whoever sent
      # it: the merged message itself names its sender.
      MESSAGE_WAITING_NOTE = [
        "note: a message from the user is waiting; the task is STILL RUNNING.",
        "  Read the message first. To keep waiting after it: task_wait %<id>s. If it is no longer needed: task_stop %<id>s."
      ].join("\n").freeze

      def self.name = NAME

      # @param cancelled [#call] true once the user stopped the turn: the
      #   wait returns then, and the task keeps running
      # @param message_waiting [#call] true once a person's message waits for
      #   the turn's next boundary (Engine#input_waiting?): the wait returns
      #   then, so the model reads it, and the task keeps running
      def self.call(task_id, timeout: TIMEOUT_DEFAULT, tail_lines: TAIL_LINES_DEFAULT, done_pattern: nil,
                    cancelled: -> { false }, message_waiting: -> { false })
        timeout = TIMEOUT_DEFAULT if blank?(timeout)
        tail_lines = TAIL_LINES_DEFAULT if blank?(tail_lines)
        timeout = timeout.to_i
        return "Error: task_id is required" if task_id.to_s.strip.empty?

        tail_lines = parse_tail_lines(tail_lines)
        return tail_lines if tail_lines.is_a?(String)

        completion_pattern = parse_done_pattern(done_pattern)
        return completion_pattern if completion_pattern.is_a?(String)

        task_id = task_id.to_s.strip
        started = monotonic_time
        deadline = started + timeout

        loop do
          record, error = TaskRuntime.get_record(task_id)
          return error if error

          return finished_response(record, tail_lines) unless record.running?

          if completion_pattern
            output_tail = output_tail(record, tail_lines)
            return format_response(record, wait_result: "pattern_matched", output_tail: output_tail, tail_lines: tail_lines) if completion_pattern.match?(output_tail)
          end

          return cancelled_response(task_id, tail_lines, started) if cancelled.call
          return message_waiting_response(task_id, tail_lines, started) if message_waiting.call

          break if monotonic_time > deadline

          sleep(POLL_INTERVAL)
        end

        # Timeout reached — do one final refresh to capture the latest status
        refreshed, = TaskRuntime.get_record(task_id)
        return finished_response(refreshed, tail_lines) unless refreshed.running?

        format_response(refreshed, wait_result: "timeout", output_tail: output_tail(refreshed, tail_lines), tail_lines: tail_lines)
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # The task may have finished between the poll and the Stop: then the
      # normal finished result. Only a task still running says so.
      def self.cancelled_response(task_id, tail_lines, started)
        record, error = TaskRuntime.get_record(task_id)
        return error if error
        return finished_response(record, tail_lines) unless record.running?

        note = [
          "note: the user stopped the turn while waiting; the task is STILL RUNNING.",
          "  To keep waiting: task_wait #{task_id}. If it is stuck or no longer needed: task_stop #{task_id}.",
          "waited: #{(monotonic_time - started).round}s"
        ]
        format_response(record, wait_result: "canceled", output_tail: output_tail(record, tail_lines), tail_lines: tail_lines,
                                extra: note)
      end
      private_class_method :cancelled_response

      # A message waits: the wait ends so the model reads it at the next
      # boundary. A task that finished meanwhile gives its finished result,
      # as after a Stop.
      def self.message_waiting_response(task_id, tail_lines, started)
        record, error = TaskRuntime.get_record(task_id)
        return error if error
        return finished_response(record, tail_lines) unless record.running?

        note = [format(MESSAGE_WAITING_NOTE, id: task_id), "waited: #{(monotonic_time - started).round}s"]
        format_response(record, wait_result: "message_waiting", output_tail: output_tail(record, tail_lines),
                                tail_lines: tail_lines, extra: note)
      end
      private_class_method :message_waiting_response

      # A finished task's text, as task_wait gives it: its status lines and
      # always the log's last lines (a test run's summary, an error), then a
      # stderr_tail when the record has a non-empty one. A task the user
      # stopped also says so. Public: a task finish wake's note
      # (TaskFinishNote) carries the same text.
      # @param record [TaskRecord] a finished one
      # @return [String] a RefText of its output_path when it has one
      def self.finished_text(record, tail_lines: TAIL_LINES_DEFAULT)
        extra = record.stopped_by_user? ? [TaskRuntime::USER_STOP_NOTE] : []
        format_response(record, output_tail: output_tail(record, tail_lines), tail_lines: tail_lines, extra: extra)
      end

      def self.finished_response(record, tail_lines) = finished_text(record, tail_lines: tail_lines)
      private_class_method :finished_response

      def self.output_tail(record, tail_lines)
        TaskRuntime.output_tail_lines(record.output_path, tail_lines)
      end
      private_class_method :output_tail

      # The last lines of a handed-over execute's stderr log (stderr_path),
      # "" for a task_create task (one log) or an empty stderr.
      def self.stderr_tail(record, tail_lines)
        path = record.stderr_path
        return "" if path.to_s.empty? || tail_lines.nil?

        TaskRuntime.output_tail_lines(path, [tail_lines, STDERR_TAIL_LINES_MAX].min)
      end
      private_class_method :stderr_tail

      def self.format_response(record, wait_result: nil, output_tail: nil, tail_lines: nil, extra: [])
        lines = [
          "task_id: #{record.id}",
          "status: #{record.status}",
          "exit_code: #{record.exit_code}",
          "stop_reason: #{record.stop_reason}",
          "output_path: #{record.output_path}"
        ]
        lines << "stderr_path: #{record.stderr_path}" if record.stderr_path
        return lines.join("\n") unless output_tail

        lines << "wait_result: #{wait_result}" if wait_result
        lines.concat(extra)
        lines << "output_tail:"
        lines << output_tail.rstrip unless output_tail.empty?
        stderr_tail = stderr_tail(record, tail_lines)
        lines.concat(["stderr_tail:", stderr_tail.rstrip]) unless stderr_tail.empty?
        # The whole log is at output_path (stderr at stderr_path): a cut of
        # this text names them.
        RefText.wrap(lines.join("\n"), record.output_path, stderr_path: record.stderr_path)
      end
      private_class_method :format_response

      def self.parse_tail_lines(value)
        parsed = Integer(value, exception: false)
        return "Error: tail_lines must be a positive integer" unless parsed&.positive?
        return "Error: tail_lines must be at most #{TAIL_LINES_MAX}" if parsed > TAIL_LINES_MAX

        parsed
      end
      private_class_method :parse_tail_lines

      def self.parse_done_pattern(value)
        return nil if blank?(value)

        Regexp.new(value.to_s)
      rescue RegexpError => e
        "Error: invalid done_pattern: #{e.message}"
      end
      private_class_method :parse_done_pattern

      def self.blank?(value)
        value.nil? || value.to_s.strip.empty?
      end
      private_class_method :blank?

      def self.monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
