# frozen_string_literal: true

require_relative "session_stats"

module ModelNotesReport
  # The sessions of one model with one set of prompt notes, and their
  # numbers together: the medians of the per-session places and runs (over
  # the sessions that have one; never: how many have none), commits per 100
  # steps pooled (all commits over all steps), and the counts summed.
  Group = Data.define(:model, :notes_key, :notes, :sessions) do
    def size = sessions.size

    def first_edit = Group.median(sessions.filter_map(&:first_edit))
    def first_commit = Group.median(sessions.filter_map(&:first_commit))
    def never_edited = sessions.count { |stats| stats.first_edit.nil? }
    def never_committed = sessions.count { |stats| stats.first_commit.nil? }
    def longest_no_edit = Group.median(sessions.map(&:longest_no_edit))
    def steps = sessions.sum(&:steps)
    def commits = sessions.sum(&:commits)
    def commits_per_100 = steps.positive? ? commits * 100.0 / steps : nil
    def bare_amp = sessions.sum(&:bare_amp)

    # Summed over the sessions with analytics.json; nil when none has it.
    def continues
      known = sessions.filter_map(&:continues)
      known.empty? ? nil : known.sum
    end

    def steers = sessions.sum(&:steers)
    def nudges = sessions.sum(&:nudges)
    def follow_ups = sessions.sum(&:follow_ups)

    def self.median(values)
      return nil if values.empty?

      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    def to_h
      { model: model, notes_key: notes_key, notes: notes.map { |note| note.to_h.compact }, sessions: size,
        session_ids: sessions.map(&:id), first_edit_median: first_edit, never_edited: never_edited,
        first_commit_median: first_commit, never_committed: never_committed, steps: steps, commits: commits,
        commits_per_100: commits_per_100&.round(2), longest_no_edit_median: longest_no_edit, bare_amp: bare_amp,
        continues: continues, steers: steers, nudges: nudges, follow_ups: follow_ups }
    end
  end

  # What the script prints: the groups (model, then notes key) and the
  # sessions in them, as a table or a JSON object. Only ids, model names,
  # note names and digests, dates and numbers: never a session's text.
  Report = Data.define(:source, :sessions, :skipped) do
    def groups
      sessions.group_by { |stats| [stats.model, stats.notes_key] }.sort.map do |(model, key), list|
        Group.new(model: model, notes_key: key, notes: list.first.notes, sessions: list.sort_by { |s| [s.created_at, s.id] })
      end
    end

    def to_h
      { source: source, sessions: sessions.size, skipped: skipped, groups: groups.map(&:to_h),
        session_rows: groups.flat_map { |group| group.sessions.map(&:to_h) } }
    end

    GROUP_COLUMNS = [["#", 3], ["n", 4], ["1st-edit", 9], ["never", 6], ["1st-commit", 11], ["never", 6],
                     ["commits/100", 12], ["no-edit", 8], ["bare&", 6], ["cont", 5], ["steer", 6], ["f-up", 5],
                     ["nudge", 6]].freeze
    SESSION_COLUMNS = [["#", 3], ["session", 9], ["created", 11], ["steps", 6], ["calls", 6], ["1st-edit", 9],
                       ["1st-commit", 11], ["commits/100", 12], ["no-edit", 8], ["bare&", 6], ["cont", 5],
                       ["steer", 6], ["f-up", 5], ["nudge", 6]].freeze

    def text
      list = groups
      lines = ["model notes report: #{sessions.size} session(s) in #{list.size} group(s) from #{source}#{skipped_text}"]
      return lines.join("\n") if list.empty?

      lines << "" << "Groups (1st-edit, 1st-commit, no-edit: medians in calls; commits/100: pooled over steps; " \
                     "the rest summed):"
      list.each_with_index { |group, index| lines << "  #{index + 1}. #{group.model}  notes: #{group.notes_key}" }
      lines << row(GROUP_COLUMNS.map(&:first), GROUP_COLUMNS)
      list.each_with_index do |group, index|
        lines << row([index + 1, group.size, group.first_edit, group.never_edited, group.first_commit,
                      group.never_committed, group.commits_per_100, group.longest_no_edit, group.bare_amp,
                      group.continues, group.steers, group.follow_ups, group.nudges], GROUP_COLUMNS)
      end
      lines << "" << "Sessions:" << row(SESSION_COLUMNS.map(&:first), SESSION_COLUMNS)
      list.each_with_index do |group, index|
        group.sessions.each do |stats|
          lines << row([index + 1, stats.id[0, 8], stats.created_at[0, 10], stats.steps, stats.calls, stats.first_edit,
                        stats.first_commit, stats.commits_per_100, stats.longest_no_edit, stats.bare_amp,
                        stats.continues, stats.steers, stats.follow_ups, stats.nudges], SESSION_COLUMNS)
        end
      end
      lines.join("\n")
    end

    private

    def skipped_text
      parts = skipped.reject { |_, count| count.zero? }.map { |why, count| "#{count} #{why.to_s.tr("_", " ")}" }
      parts.empty? ? "" : " (skipped: #{parts.join(", ")})"
    end

    def row(values, columns)
      cells = values.zip(columns).map do |value, (_, width)|
        cell(value).rjust(width)
      end
      "  #{cells.join(" ")}".rstrip
    end

    def cell(value)
      case value
      when nil then "-"
      when Float then value == value.round ? value.round.to_s : format("%.1f", value)
      else value.to_s
      end
    end
  end
end
