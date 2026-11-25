# frozen_string_literal: true

require_relative "schedules"

module Samagotchi
  # What a schedule is called when it is listed: `chi schedule list` and the
  # `list_schedules` tool both use this, so a schedule reads the same in the
  # terminal and to the model. The name is its title when it has one; a schedule
  # made without a title is named by the start of its prompt, in quotes, cut at
  # PROMPT_CHARS with "…" where the cut falls. The name is display only: the
  # entry keeps its title as given (nil when there is none) and its whole prompt.
  module ScheduleDisplay
    # How much of a titleless prompt the name shows.
    PROMPT_CHARS = 30

    # @param entry [Schedules::Entry]
    # @param width [Integer, nil] pad to this width — the widest name among the
    #   rows being printed — so the columns after the name line up; without it
    #   the name is just the name.
    def self.name(entry, width: nil)
      given = entry.title.to_s.strip
      if given.empty?
        words = entry.prompt.to_s.gsub(/\s+/, " ").strip
        given = words.length > PROMPT_CHARS ? "\"#{words[0, PROMPT_CHARS]}…\"" : "\"#{words}\""
      end
      width ? given.ljust(width) : given
    end

    # An entry's condition as it is listed: its command (cut at +chars+ with
    # "…" when given), or what a condition that doesn't read is. nil without
    # one.
    def self.condition_words(entry, chars: nil)
      condition = entry.condition
      return nil if condition.nil?

      cmd = condition.is_a?(Hash) ? condition[:cmd] : nil
      return "(doesn't read: the tick fails it)" unless cmd.is_a?(String)

      chars && cmd.length > chars ? "#{cmd[0, chars]}…" : cmd
    end

    # The width of the name column for these entries.
    def self.name_width(entries)
      entries.map { |entry| name(entry) }.map(&:length).max
    end

    # The history statuses that are outcomes of a firing (HistoryPart): the
    # owner's enabled/disabled and an edit's rows say nothing of how a
    # one-off ended.
    OUTCOMES = %w[fired failed missed skipped].freeze

    # "firing" while a firing is under way (a tick holds it, or its turn is
    # pending: a one-off is already off then, see Schedules#advance), "on"
    # when enabled, else "off".
    # @param entry [Schedules::Entry]
    def self.state(entry)
      return "firing" if entry.firing_since || entry.pending_session_id

      entry.enabled ? "on" : "off"
    end

    # Why an off schedule is off, nil when it isn't (state on or firing):
    #   "owner"     turned off by `chi schedule disable` (its last result)
    #   "skips"     its skip budget ran out (max_skips)
    #   "failures"  its failure budget ran out (max_failures), or a one-off
    #               whose firing failed
    #   "done"      a one-off that fired
    #   "missed"    a one-off whose moment passed unseen
    #   "off"       none of these (an older file's spent one-off)
    # A one-off's reason is its last outcome row in the history (OUTCOMES),
    # never `enabled: false` alone: firing, failing and missing all turn a
    # one-off off.
    def self.off_reason(entry)
      return nil unless state(entry) == "off"
      return "owner" if entry.last_result == "disabled"
      return "skips" if entry.skips >= entry.max_skips
      return "failures" if entry.failures >= entry.max_failures
      return "off" unless entry.recurrence[:kind] == "date"

      case entry.history.reverse.find { |row| OUTCOMES.include?(row[:status]) }&.dig(:status)
      when "fired" then "done"
      when "failed" then "failures"
      when "missed" then "missed"
      when "skipped" then "skips"
      else "off"
      end
    end

    # A skip budget as a time window: 3 of 12 at a 5 minute tick is about 1
    # hour of patience, which is what the count really measures.
    def self.skip_window(entry)
      tick = Schedules.tick_interval_minutes
      minutes = entry.max_skips * tick
      hours = minutes / 60.0
      hours >= 1 ? "≈#{(hours * 10).round / 10} h at a #{tick} min tick" : "≈#{minutes} min"
    end

    # One entry as `chi schedule list --format json` prints it (and
    # Pages::Runtime reads it): every stored field with its extra keys (the
    # real next_due: the file's hidden one is Schedules#write's), the
    # condition with string keys, then what a reader needs and would
    # otherwise compute: recurrence_words, skip_window, name, state,
    # off_reason. Those come last, so an extra key of the same name (a newer
    # chi's) never shadows them.
    # @return [Hash{String => Object}]
    def self.json(entry)
      condition = entry.condition.is_a?(Hash) ? entry.condition.transform_keys(&:to_s) : entry.condition
      entry.to_h.transform_keys(&:to_s).merge("condition" => condition).merge(
        "recurrence_words" => entry.recurrence_words,
        "skip_window" => skip_window(entry),
        "name" => name(entry),
        "state" => state(entry),
        "off_reason" => off_reason(entry)
      )
    end
  end
end
