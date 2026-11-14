# frozen_string_literal: true

require_relative "task_runtime"
require_relative "../tool_names"

module Samagotchi
  module Tools
    class TaskStop
      NAME = ToolNames::TaskStop::NAME

      def self.name = NAME

      def self.call(task_id)
        record, error = TaskRuntime.stop_task(task_id.to_s.strip, by: "model")
        return error if error

        [
          "task_id: #{record.id}",
          "status: #{record.status}",
          "exit_code: #{record.exit_code}",
          "finished_at: #{record.finished_at}",
          "stop_reason: #{record.stop_reason}",
          "output_path: #{record.output_path}"
        ].join("\n")
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end
end
