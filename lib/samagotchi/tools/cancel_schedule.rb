# frozen_string_literal: true

require_relative "../tool_names"

module Samagotchi
  module Tools
    # Cancel a durable schedule of this session's chain by its id, a unique
    # prefix of it, or its title (docs/scheduling.md). A schedule of another
    # session's chain is refused unless the call says `all: true`: `chi
    # schedule cancel` is the machine-wide way. An entry of schedules.json
    # that doesn't read (which list leaves out) goes by its exact id, as
    # chi schedule cancel ID takes it: in this chain when its stored anchor
    # or head is a link of it, else refused like another chain's; one whose
    # chain can't be told (neither stored) only with `all: true`.
    class CancelSchedule
      NAME = ToolNames::CancelSchedule::NAME

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
        return cancel_unreadable(schedules, name, want_all, peers) if entry.nil?

        # nil: gone since the lookup (another cancel in between).
        if want_all || peers&.session_id.nil?
          return "No schedule named #{name}." unless schedules.cancel(name)

          return "Cancelled #{entry.id} (#{entry.title || entry.recurrence_words})."
        end

        unless schedules.chain_of(peers.session_id).any? { |id| id == entry.anchor || id == entry.head }
          return "Error: #{entry.id} belongs to another session's chain. " \
                 "chi schedule cancel #{entry.id} cancels it, or say all: true if you meant it."
        end

        return "No schedule named #{name}." unless schedules.cancel(name)

        "Cancelled #{entry.id} (#{entry.title || entry.recurrence_words})."
      rescue StandardError => e
        "Error: #{e.message}"
      end

      # @return [String] the answer for +name+ when no readable entry has it
      def self.cancel_unreadable(schedules, name, want_all, peers)
        raw = schedules.unreadable_record(name)
        return "No schedule named #{name}." if raw.nil?

        unless want_all || peers&.session_id.nil?
          ends = [raw["anchor"], raw["head"]].select { |id| id.is_a?(String) && !id.empty? }
          if ends.empty?
            return "Error: schedule #{name} can't be read, so its chain can't be told. " \
                   "chi schedule cancel #{name} removes it, or say all: true if you meant it."
          end
          unless schedules.chain_of(peers.session_id).any? { |id| ends.include?(id) }
            return "Error: #{name} belongs to another session's chain. " \
                   "chi schedule cancel #{name} cancels it, or say all: true if you meant it."
          end
        end
        return "No schedule named #{name}." unless schedules.cancel(name)

        "Cancelled #{name} (it couldn't be read)."
      end
    end
  end
end
