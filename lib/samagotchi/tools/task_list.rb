# frozen_string_literal: true

require_relative "task_runtime"

module Samagotchi
  module Tools
    class TaskList
      NAME = "task_list"
      COMMAND_PREVIEW_LIMIT = 80

      def self.name = NAME

      def self.call(_content = nil)
        records = TaskRuntime.list_records
        return "No tasks found." if records.empty?

        records.map { |record| format_entry(record) }.join("\n\n")
      rescue StandardError => e
        "Error: #{e.message}"
      end

      def self.format_entry(record)
        [
          "task_id: #{record.fetch("id")}",
          "status: #{record.fetch("status")}",
          "pid: #{record.fetch("pid")}",
          "created_at: #{record.fetch("created_at")}",
          "command: #{preview(record.fetch("command"))}",
          "output_path: #{record.fetch("output_path")}"
        ].join("\n")
      end
      private_class_method :format_entry

      def self.preview(value)
        text = value.to_s.gsub(/\s+/, " ").strip
        return "" if text.length <= COMMAND_PREVIEW_LIMIT

        text[0, COMMAND_PREVIEW_LIMIT - 1] + "…"
      end
      private_class_method :preview
    end
  end
end
