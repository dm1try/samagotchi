# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskWait
      NAME = "task_wait"
      TIMEOUT_DEFAULT = 600
      TAIL_LINES_DEFAULT = 10
      TAIL_LINES_MAX = 100
      POLL_INTERVAL = 0.5

      def self.name = NAME

      # @param cancelled [#call] true once the user stopped the turn: the
      #   wait returns then, and the task keeps running
      def self.call(task_id, timeout: TIMEOUT_DEFAULT, tail_lines: TAIL_LINES_DEFAULT, done_pattern: nil,
                    cancelled: -> { false })
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
          return "Error: #{error}" if error

          status = record.fetch("status")
          return format_response(record) unless status == "running"

          if completion_pattern
            output_tail = TaskRuntime.output_tail_lines(record.fetch("output_path"), tail_lines)
            return format_response(record, wait_result: "pattern_matched", output_tail: output_tail) if completion_pattern.match?(output_tail)
          end

          return cancelled_response(task_id, tail_lines, started) if cancelled.call

          break if monotonic_time > deadline

          sleep(POLL_INTERVAL)
        end

        # Timeout reached — do one final refresh to capture the latest status
        refreshed, = TaskRuntime.get_record(task_id)
        return format_response(refreshed) unless refreshed.fetch("status") == "running"

        output_tail = TaskRuntime.output_tail_lines(refreshed.fetch("output_path"), tail_lines)
        format_response(refreshed, wait_result: "timeout", output_tail: output_tail)
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # The task may have finished between the poll and the Stop: then the
      # normal finished result. Only a task still running says so.
      def self.cancelled_response(task_id, tail_lines, started)
        record, error = TaskRuntime.get_record(task_id)
        return "Error: #{error}" if error
        return format_response(record) unless record.fetch("status") == "running"

        output_tail = TaskRuntime.output_tail_lines(record.fetch("output_path"), tail_lines)
        note = [
          "note: the user stopped the turn while waiting; the task is STILL RUNNING.",
          "  To keep waiting: task_wait #{task_id}. If it is stuck or no longer needed: task_stop #{task_id}.",
          "waited: #{(monotonic_time - started).round}s"
        ]
        format_response(record, wait_result: "canceled", output_tail: output_tail, extra: note)
      end
      private_class_method :cancelled_response

      def self.format_response(record, wait_result: nil, output_tail: nil, extra: [])
        lines = [
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "exit_code: #{record["exit_code"]}",
          "stop_reason: #{record["stop_reason"]}",
          "output_path: #{record.fetch("output_path")}"
        ]
        return lines.join("\n") unless wait_result

        lines << "wait_result: #{wait_result}"
        lines.concat(extra)
        lines << "output_tail:"
        lines << output_tail.rstrip unless output_tail.empty?
        lines.join("\n")
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
