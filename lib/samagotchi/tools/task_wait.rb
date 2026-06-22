
# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskWait
      NAME = "task_wait"
      DESCRIPTION = "Wait for a background task to finish. Polls every 0.5s until the task completes or the timeout is reached. Returns status and output path."
      TIMEOUT_DEFAULT = 60
      POLL_INTERVAL = 0.5

      def self.name = NAME
      def self.description = DESCRIPTION

      def self.call(task_id, timeout: TIMEOUT_DEFAULT)
        timeout = timeout.to_i
        return "Error: task_id is required" if task_id.to_s.strip.empty?

        task_id = task_id.to_s.strip
        deadline = monotonic_time + timeout

        loop do
          record, error = TaskRuntime.get_record(task_id)
          return "Error: #{error}" if error

          status = record.fetch("status")
          return format_response(record) unless status == "running"

          break if monotonic_time > deadline
          sleep(POLL_INTERVAL)
        end

        # Timeout reached — do one final refresh to capture the latest status
        refreshed, _ = TaskRuntime.get_record(task_id)
        format_response(refreshed)
      rescue => e
        "Error: #{e.message}"
      end

      def self.format_response(record)
        [
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "exit_code: #{record["exit_code"]}",
          "stop_reason: #{record["stop_reason"]}",
          "output_path: #{record.fetch("output_path")}"
        ].join("\n")
      end
      private_class_method :format_response

      def self.monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end

