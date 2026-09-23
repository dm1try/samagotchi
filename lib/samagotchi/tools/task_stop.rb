# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskStop
      NAME = "task_stop"

      def self.name = NAME

      def self.call(task_id)
        record, error = TaskRuntime.stop_task(task_id.to_s.strip)
        return error if error

        [
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "exit_code: #{record["exit_code"]}",
          "finished_at: #{record["finished_at"]}",
          "stop_reason: #{record["stop_reason"]}",
          "output_path: #{record.fetch("output_path")}"
        ].join("\n")
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
