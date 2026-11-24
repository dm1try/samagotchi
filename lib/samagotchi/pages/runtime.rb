# frozen_string_literal: true

require_relative "../pages"

module Samagotchi
  module Pages
    # What a page script reads of chi itself: `runtime` in a script
    # (Runner::Collector#dsl), one per run (docs/pages.md, "Reading chi's
    # data"). Each method reads in this process, from this chi's code: no
    # `chi` on PATH, no second boot, read-only. Each requires what it reads
    # only when called, so a page that never calls it stays as light as the
    # runner (spec/pages_runtime_spec.rb loads one to check).
    #
    #   runtime.schedules   every durable schedule (ScheduleList)
    #
    # A method comes with its first page (docs/internals/pages.md).
    class Runtime
      # What a runtime read can't give: the run fails with its message.
      class Unreadable < Error; end

      # One row of a schedule's history (Schedules::HistoryPart): when, what
      # (fired, skipped, failed, missed, enabled, disabled, edited), why, and
      # the session it acted on. Times are ISO 8601 UTC strings.
      Run = Data.define(:at, :status, :detail, :session_id)

      # The members a Schedule has: the keys of `chi schedule list --format
      # json` (ScheduleDisplay.json) a page may rely on. The others (a
      # firing's token, its pending turn, extra keys) are chi's bookkeeping.
      SCHEDULE_MEMBERS = %i[id name title mode prompt recurrence_words next_due last_fired last_result enabled state
                            off_reason skips max_skips failures max_failures skip_window anchor head created_at
                            history].freeze

      # One schedule as `chi schedule list --format json` says it: +name+ is
      # its title or the start of its prompt in quotes, +state+ "on",
      # "firing" or "off", +off_reason+ why it is off (ScheduleDisplay.off_reason:
      # "owner", "skips", "failures", "done", "missed", "off"; nil when it
      # isn't), +history+ its Runs, oldest first. Times are ISO 8601 UTC
      # strings, nil when there is none.
      Schedule = Data.define(*SCHEDULE_MEMBERS) do
        # @param json [Hash{String => Object}] ScheduleDisplay.json's; a
        #   missing key reads as nil (history as none), an unknown one is
        #   dropped
        def self.from_json(json)
          fields = SCHEDULE_MEMBERS.to_h { |member| [member, json[member.to_s]] }
          fields[:history] = Array(json["history"]).filter_map do |row|
            row = row.transform_keys(&:to_s) if row.is_a?(Hash)
            row.is_a?(Hash) ? Run.new(at: row["at"], status: row["status"], detail: row["detail"], session_id: row["session_id"]) : nil
          end
          new(**fields)
        end

        # The schedule as a table row (ui.table): every member but history,
        # string keys.
        def row = to_h.except(:history).transform_keys(&:to_s)
      end

      # Every schedule (+entries+, Schedules, the earliest due first),
      # Schedules#tick_warning's text when nothing ticks (+warning+, else
      # nil), and the id of each entry schedules.json holds that doesn't read
      # (+unreadable_ids+, nil for one with no id).
      ScheduleList = Data.define(:entries, :warning, :unreadable_ids) do
        include Enumerable

        def each(&) = entries.each(&)

        # Every schedule as a table row: `ui.table runtime.schedules.rows, columns: …`.
        def rows = entries.map(&:row)
      end

      # @return [ScheduleList]
      # @raise [Unreadable] schedules.json isn't readable JSON (Schedules::Corrupt's words)
      def schedules
        require_relative "../schedules"
        require_relative "../schedule_display"
        listing = Schedules.new.listing
        ScheduleList.new(entries: listing.entries.map { |entry| Schedule.from_json(ScheduleDisplay.json(entry)) },
                         warning: listing.warning, unreadable_ids: listing.unreadable_ids)
      rescue Schedules::Corrupt => e
        raise Unreadable, e.message
      end
    end
  end
end
