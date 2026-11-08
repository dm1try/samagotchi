# frozen_string_literal: true

module Samagotchi
  module Tools
    # The durable schedules of this session's chain (docs/scheduling.md): id,
    # mode, recurrence, next due and target. Another session's schedules are
    # out of reach unless the call says `all: true`; `chi schedule list` is the
    # machine-wide view. Schedules is required inside the call, so the testing
    # kit does not pay for the session lifecycle at load time.
    class ListSchedules
      NAME = "list_schedules"

      def self.name = NAME

      def self.call(_content, include_disabled: false, all: false, peers: nil)
        wanted = include_disabled == true || include_disabled.to_s.strip.casecmp?("true")
        want_all = all == true || all.to_s.strip.casecmp?("true")
        schedules = Samagotchi::Schedules.new(state_dir: peers&.state_dir)

        scoped = !want_all && peers&.session_id
        entries = scoped ? schedules.for_chain(peers.session_id, include_disabled: wanted) : schedules.entries(include_disabled: wanted)

        if entries.empty?
          scoped ? "No schedules in this session's chain. `chi schedule list` shows every schedule on this machine." : "No schedules."
        else
          lines = entries.map do |entry|
            flags = []
            flags << "skips #{entry.skips} of #{entry.max_skips}" if entry.skips.positive?
            flags << "disabled after #{entry.failures} failures" unless entry.enabled
            "#{entry.id}  #{entry.target_words}  #{entry.recurrence_words}  next #{entry.next_due}  #{flags.join(", ")}".rstrip
          end
          lines << "These are this session's chain only; `chi schedule list` shows every schedule on this machine." if scoped
          lines.join("\n")
        end
      rescue StandardError => e
        "Error: #{e.message}"
      end
    end
  end
end
