# frozen_string_literal: true

require_relative "../schedules"

module Samagotchi
  module Tools
    # Cancel a durable schedule by its id, a unique prefix of it, or its title
    # (docs/scheduling.md).
    class CancelSchedule
      NAME = "cancel_schedule"

      def self.name = NAME

      def self.call(content, peers: nil)
        name = content.to_s.strip
        return "Error: cancel_schedule needs the schedule's id or title" if name.empty?

        schedules = Schedules.new(state_dir: peers&.state_dir)
        entry = schedules.cancel(name)
        return "No schedule named #{name}." if entry.nil?

        "Cancelled #{entry.id} (#{entry.title || entry.recurrence_words})."
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end
end
