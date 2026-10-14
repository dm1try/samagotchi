# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskGet
      NAME = "task_get"

      def self.name = NAME

      def self.call(task_id)
        record, error = TaskRuntime.get_record(task_id.to_s.strip)
        return error if error

        format_record(record)
      rescue StandardError => e
        "Error: #{e.message}"
      end

      def self.format_record(record)
        [
          "task_id: #{record.id}",
          "status: #{record.status}",
          "command: #{record.command}",
          "cwd: #{record.cwd}",
          "pid: #{record.pid}",
          "created_at: #{record.created_at}",
          "started_at: #{record.started_at}",
          "finished_at: #{record.finished_at}",
          "exit_code: #{record.exit_code}",
          "stop_reason: #{record.stop_reason}",
          "output_path: #{record.output_path}",
          # A handed-over execute's stderr has a log of its own.
          ("stderr_path: #{record.stderr_path}" if record.stderr_path),
          (TaskRuntime::USER_STOP_NOTE if record.stopped_by_user?)
        ].compact.join("\n")
      end
      private_class_method :format_record
    end
  end
end
