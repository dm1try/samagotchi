# frozen_string_literal: true

require "date"
require "time"

module Samagotchi
  class Schedules
    # The recurrence parsing (docs/scheduling.md, Recurrence): the class
    # methods `chi schedule add` and the schedule tools build a
    # recurrence with, and the local-clock helpers the next-due math uses.
    # They raise Schedules::Usage (schedules.rb).

    # A recurrence from the CLI's flags or the tool's arguments. Blank strings
    # (what a model sends for the fields it did not use) count as absent.
    # @return [Hash] {kind:, ...}
    # @raise [Usage] none or more than one kind given, or an interval that is
    #   not a positive amount of time
    def self.recurrence(every: nil, weekday: nil, time: nil, date: nil)
      every = nil if every.to_s.strip.empty?
      weekday = nil if weekday.to_s.strip.empty?
      time = nil if time.to_s.strip.empty?
      date = nil if date.to_s.strip.empty?

      kinds = [every, weekday, date].compact
      raise Usage, "a schedule needs one of every, weekday or date" if kinds.empty?
      raise Usage, "give one of every, weekday or date, not more" if kinds.size > 1

      if every
        raise Usage, "time is only for a weekday schedule" if time && !weekday

        interval = every.to_s.strip
        raise Usage, "every needs an interval like 30m, 2h or 1d, got #{every}" unless interval.match?(/\A\d+[smhd]?\z/)

        seconds = interval_seconds(interval)
        raise Usage, "every must be at least 1s, got #{every}" if seconds.nil? || seconds.zero?

        { kind: "every", interval: interval }
      elsif weekday
        raise Usage, "weekday needs time HH:MM" if time.nil?

        day = weekday.to_s.strip
        raise Usage, "weekday must be 1 (Mon) to 7 (Sun), got #{weekday}" unless day.match?(/\A[1-7]\z/)

        { kind: "weekday", weekday: day.to_i, time: time.to_s.strip }
      else
        { kind: "date", at: local_moment(*parse_local(date)).utc.iso8601 }
      end
    end

    # The length of an interval in seconds; nil for something that is not an
    # interval, and nil for zero so a `0m` schedule can never fire every tick.
    def self.interval_seconds(interval)
      match = interval.to_s.strip.match(/\A(\d+)(s|m|h|d)?\z/)
      return nil unless match

      seconds = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, nil => 60 }[match[2]] * match[1].to_i
      seconds.positive? ? seconds : nil
    end

    def self.parse_clock(time)
      match = time.to_s.strip.match(/\A(\d{1,2}):(\d{1,2})\z/)
      raise Usage, "time must be HH:MM, got #{time}" unless match

      hour = match[1].to_i
      minute = match[2].to_i
      raise Usage, "time must be HH:MM, got #{time}" unless (0..23).cover?(hour) && (0..59).cover?(minute)

      [hour, minute]
    end

    def self.parse_local(text)
      match = text.to_s.strip.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2}))?\z/)
      raise Usage, "date must be YYYY-MM-DD or YYYY-MM-DDTHH:MM, got #{text}" unless match

      year = match[1].to_i
      month = match[2].to_i
      day = match[3].to_i
      hour = match[4] ? match[4].to_i : 0
      minute = match[5] ? match[5].to_i : 0
      unless Date.valid_date?(year, month, day) && (0..23).cover?(hour) && (0..59).cover?(minute)
        raise Usage, "date must be a real date, got #{text}"
      end

      [year, month, day, hour, minute]
    end

    # A local moment that exists. When the requested minute falls in a
    # spring-forward gap, the first valid minute whose wall clock is at or
    # after it.
    def self.local_moment(year, month, day, hour, minute)
      moment = Time.local(year, month, day, hour, minute)
      return moment if moment.hour == hour && moment.min == minute

      wanted = (hour * 60) + minute
      day_start = Time.local(year, month, day, 0, 0)
      1440.times do |step|
        probe = day_start + (step * 60)
        return probe if (probe.hour * 60) + probe.min >= wanted
      end
      moment
    end
  end
end
