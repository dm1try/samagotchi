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
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "command: #{record.fetch("command")}",
          "cwd: #{record.fetch("cwd")}",
          "pid: #{record.fetch("pid")}",
          "created_at: #{record.fetch("created_at")}",
          "started_at: #{record.fetch("started_at")}",
          "finished_at: #{record["finished_at"]}",
          "exit_code: #{record["exit_code"]}",
          "stop_reason: #{record["stop_reason"]}",
          "output_path: #{record.fetch("output_path")}"
        ].join("\n")
      end
      private_class_method :format_record
    end
  end
end
