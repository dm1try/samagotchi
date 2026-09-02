# frozen_string_literal: true

require_relative "../reminder_store"

module Samagotchi
  module Tools
    # Lists all active registered reminders.
    class ListReminders
      NAME        = "list_reminders"
      DESCRIPTION = "List all active registered reminders."

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(content, reminder_store: nil)
        return "Error: reminder_store not configured" unless reminder_store

        reminder_store.list
      end
    end
  end
end
