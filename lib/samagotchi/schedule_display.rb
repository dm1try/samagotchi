# frozen_string_literal: true

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

    # The width of the name column for these entries.
    def self.name_width(entries)
      entries.map { |entry| name(entry) }.map(&:length).max
    end
  end
end
