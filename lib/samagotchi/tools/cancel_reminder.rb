# frozen_string_literal: true

require_relative "../reminder_store"

module Samagotchi
  module Tools
    # Cancels a previously registered reminder by name.
    class CancelReminder
      NAME        = "cancel_reminder"

      def self.name        = NAME

      def self.call(content, reminder_store: nil)
        return "Error: reminder_store not configured" unless reminder_store

        name = content.to_s.strip
        reminder_store.cancel(name)
      end
    end
  end
end
