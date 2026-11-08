# frozen_string_literal: true

require_relative "../schedules"

module Samagotchi
  module Tools
    # Every durable schedule this machine has: id, mode, recurrence, next due
    # and target. See docs/scheduling.md.
    class ListSchedules
      NAME = "list_schedules"

      def self.name = NAME

      def self.call(_content, include_disabled: false, peers: nil)
        wanted = include_disabled == true || include_disabled.to_s.strip.casecmp?("true")
        schedules = Schedules.new(state_dir: peers&.state_dir)
        entries = schedules.entries(include_disabled: wanted)
        return "No schedules." if entries.empty?

        entries.map do |entry|
          flags = []
          flags << "skips #{entry.skips} of #{entry.max_skips}" if entry.skips.positive?
          flags << "disabled after #{entry.failures} failures" unless entry.enabled
          "#{entry.id}  #{entry.target_words}  #{entry.recurrence_words}  next #{entry.next_due}  #{flags.join(", ")}".rstrip
        end.join("\n")
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end
end
