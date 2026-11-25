# frozen_string_literal: true

require "time"
require_relative "../config"

module Samagotchi
  class Schedules
    # What a reader is told of the store without changing it: the tick
    # warning (`chi schedule list`, `add`) and #listing (Pages::Runtime's
    # one read).
    module ListingPart
      # The warning `chi schedule` prints when nothing ticks (auto_tick off and
      # no tick in two intervals), nil when something does.
      def tick_warning(now: @clock.call) = tick_warning_for(read.attributes[:last_tick_at], now)

      # Every schedule as the file holds it now, for a reader that shows them
      # (Pages::Runtime#schedules): one strict read, no lock, no write, and no
      # notice claimed (#claim_disabled_notices is chi web's). +entries+ the
      # readable ones, the earliest due first (as #entries with
      # include_disabled); +unreadable_ids+ the id of each entry that doesn't
      # read (nil for one with none); +warning+ #tick_warning's text, from the
      # same read.
      Listing = Data.define(:entries, :unreadable_ids, :warning)

      # @return [Listing]
      # @raise [Corrupt] schedules.json isn't readable JSON (#entries reads it
      #   as no schedules)
      def listing(now: @clock.call)
        file = read(strict: true)
        entries = file.entries.grep(Entry).sort_by { |entry| [entry.next_due.to_s, entry.id] }
        unreadable = file.entries.grep_v(Entry).map { |record| record.raw.is_a?(Hash) ? record.raw["id"]&.to_s : nil }
        Listing.new(entries: entries, unreadable_ids: unreadable, warning: tick_warning_for(file.attributes[:last_tick_at], now))
      end

      private

      # #tick_warning's rule, given the file's last_tick_at.
      def tick_warning_for(last_tick_at, now)
        return if Config.get("schedule.auto_tick")

        stale_after = self.class.tick_interval_minutes * 120
        return if last_tick_at && now - Time.iso8601(last_tick_at.to_s) <= stale_after

        "Warning: no schedule tick in the last #{stale_after / 60} minutes; set schedule.auto_tick: true or " \
          "run `chi schedule tick` from cron."
      rescue ArgumentError
        "Warning: no schedule tick in the last #{self.class.tick_interval_minutes * 2} minutes; " \
          "set schedule.auto_tick: true or run `chi schedule tick` from cron."
      end
    end
  end
end
