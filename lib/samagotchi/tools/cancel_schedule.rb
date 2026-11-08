# frozen_string_literal: true

module Samagotchi
  module Tools
    # Cancel a durable schedule of this session's chain by its id, a unique
    # prefix of it, or its title (docs/scheduling.md). A schedule of another
    # session's chain is refused unless the call says `all: true`: `chi
    # schedule cancel` is the machine-wide way.
    class CancelSchedule
      NAME = "cancel_schedule"

      def self.name = NAME

      def self.call(content, all: false, peers: nil)
        # Required here, not at the top of the file: the kit does not pay
        # for the session lifecycle until a schedule is actually used.
        require_relative "../schedules"
        name = content.to_s.strip
        return "Error: cancel_schedule needs the schedule's id or title" if name.empty?

        want_all = all == true || all.to_s.strip.casecmp?("true")
        schedules = Schedules.new(state_dir: peers&.state_dir)
        entry = schedules.lookup(name)
        return "No schedule named #{name}." if entry.nil?

        if want_all || peers&.session_id.nil?
          schedules.cancel(name)
          return "Cancelled #{entry.id} (#{entry.title || entry.recurrence_words})."
        end

        unless schedules.chain_of(peers.session_id).any? { |id| id == entry.anchor || id == entry.head }
          return "Error: #{entry.id} belongs to another session's chain. " \
                 "chi schedule cancel #{entry.id} cancels it, or say all: true if you meant it."
        end

        schedules.cancel(name)
        "Cancelled #{entry.id} (#{entry.title || entry.recurrence_words})."
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end
end
