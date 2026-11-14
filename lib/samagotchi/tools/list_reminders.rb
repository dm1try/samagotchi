# frozen_string_literal: true

require_relative "../reminder_store"
require_relative "../tool_names"

module Samagotchi
  module Tools
    # Lists all active registered reminders.
    class ListReminders
      NAME        = ToolNames::ListReminders::NAME

      def self.name        = NAME

      def self.call(_content, reminder_store: nil)
        return "Error: reminder_store not configured" unless reminder_store

        reminder_store.list
      end
    end
  end
end
