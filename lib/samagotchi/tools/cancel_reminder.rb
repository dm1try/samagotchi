# frozen_string_literal: true

require_relative "../reminder_store"
require_relative "../tool_names"

module Samagotchi
  module Tools
    # Cancels a previously registered reminder by name.
    class CancelReminder
      NAME        = ToolNames::CancelReminder::NAME

      def self.name        = NAME

      def self.call(content, reminder_store: nil)
        return "Error: reminder_store not configured" unless reminder_store

        name = content.to_s.strip
        reminder_store.cancel(name)
      end
    end
  end
end
