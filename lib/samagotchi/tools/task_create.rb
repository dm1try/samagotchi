# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskCreate
      NAME = "task_create"
      DESCRIPTION = "Create a background task for a long-running shell command. Returns task id and output path."

      def self.name = NAME
      def self.description = DESCRIPTION

      def self.call(command, cwd: nil)
        record, error = TaskRuntime.create_task(command, cwd: cwd)
        return error if error

        [
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "pid: #{record.fetch("pid")}",
          "created_at: #{record.fetch("created_at")}",
          "output_path: #{record.fetch("output_path")}",
          "cwd: #{record.fetch("cwd")}"
        ].join("\n")
      rescue => e
        "Error: #{e.message}"
      end
    end
  end
end
