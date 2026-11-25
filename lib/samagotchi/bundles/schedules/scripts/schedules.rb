# frozen_string_literal: true

# The Schedules page (#/p/schedules), from the schedules bundle
# (docs/scheduling.md): every durable schedule, why one is off, and the
# recent runs. Read-only: chi changes a schedule when asked, or
# `chi schedule enable ID` and the rest do. To make it your own, copy this
# file to ~/.config/samagotchi/pages/schedules.rb (chi page list --format
# json gives its path as script) and change it: yours replaces this one.

require "time"

# The text reads as plain text too (chi web's Markdown is off by default): no
# headings or bold, only `code` around a command.

# How many rows each table shows; the rest are counted, not drawn.
SCHEDULE_ROWS = 100
RUN_ROWS = 50
# How many lines the "Turned off" and "Can't be read" texts show, and how
# much of a name or a reason a line keeps: a text block holds at most 16 KB,
# and schedule.max_total can be raised.
TEXT_LINES = 20
NAME_CHARS = 60
REASON_CHARS = 80

def cut(text, chars) = text.size > chars ? "#{text[0, chars - 1]}…" : text

# The first TEXT_LINES of +lines+, and a line counting the rest.
def capped(lines, rest_hint)
  return lines if lines.size <= TEXT_LINES

  lines.first(TEXT_LINES) + ["- and #{lines.size - TEXT_LINES} more: #{rest_hint}"]
end

# A time as the page shows it, in this machine's zone; nil for none.
def clock(iso)
  return nil if iso.nil? || iso.to_s.empty?

  Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
rescue ArgumentError
  iso.to_s
end

def plural(count, word) = "#{count} #{word}#{"s" unless count == 1}"

# A failure that turned it off before its budget ran out: a one-off's.
def failed_once?(schedule) = schedule.failures < schedule.max_failures

# The State column: on, firing, or off with why (off_reason).
def state_words(schedule)
  case schedule.off_reason
  when nil then schedule.state
  when "owner" then "off: you"
  when "skips" then "off: #{plural(schedule.skips, "skip")}"
  when "failures" then failed_once?(schedule) ? "off: failed" : "off: #{plural(schedule.failures, "failure")}"
  when "done" then "done"
  when "missed" then "missed"
  else "off"
  end
end

# Why an off schedule is off, in a sentence's words.
def why_off(schedule)
  case schedule.off_reason
  when "owner" then "turned off by you"
  when "skips" then "skipped #{plural(schedule.skips, "time")} (#{schedule.skip_window})"
  when "failures" then failed_once?(schedule) ? "one-off, failed" : "failed #{plural(schedule.failures, "time")}"
  when "done" then "one-off, done"
  when "missed" then "one-off, missed"
  else "off"
  end
end

# What the last skip or failure said (a budget's last row reads "disabled: …").
def last_reason(schedule)
  row = schedule.history.reverse.find { |run| %w[skipped failed].include?(run.status) }
  row&.detail.to_s.delete_prefix("disabled: ")
end

def off_line(schedule)
  line = "- #{cut(schedule.name.to_s, NAME_CHARS)} — #{why_off(schedule)}"
  reason = %w[skips failures].include?(schedule.off_reason) ? cut(last_reason(schedule), REASON_CHARS) : ""
  line += ": #{reason}" unless reason.empty?
  # A one-off that ran or was missed is over: nothing to turn on.
  line += " · `chi schedule enable #{schedule.id}`" unless %w[done missed].include?(schedule.off_reason)
  line
end

def unreadable_lines(ids)
  lines = ids.compact.map do |id|
    # An id too long to show can't be given to cancel either.
    next "- schedule #{cut(id, NAME_CHARS)} can't be read: fix or remove it in schedules.json" if id.size > NAME_CHARS

    "- schedule #{id} can't be read: `chi schedule cancel #{id}` removes it"
  end
  lines = capped(lines, "`chi schedule list` names none of them; schedules.json has them")
  nameless = ids.count(nil)
  lines << "- #{plural(nameless, "schedule")} with no id can't be read: fix or remove it in schedules.json" if nameless.positive?
  lines
end

page "Schedules" do |ui|
  list = runtime.schedules
  if list.entries.empty? && list.unreadable_ids.empty?
    ui.text "No schedules yet. Ask chi (\"check the CI every morning at 9\") or run " \
            "`chi schedule add --session ID --every 1d -m \"…\"`; see docs/scheduling.md."
    next
  end

  counts = list.entries.map(&:state).tally
  states = %w[on firing off].filter_map { |state| "#{counts[state]} #{state}" if counts[state] }
  summary = "#{plural(list.entries.size, "schedule")}#{": #{states.join(", ")}" unless states.empty?}. Refresh to update."
  ui.text [summary, list.warning].compact.join("\n\n")

  off = list.entries.select { |schedule| schedule.state == "off" }
  ui.text "Turned off:\n\n#{capped(off.map { |schedule| off_line(schedule) }, "`chi schedule list --all`").join("\n")}" unless off.empty?
  ui.text "Can't be read:\n\n#{unreadable_lines(list.unreadable_ids).join("\n")}" unless list.unreadable_ids.empty?

  next if list.entries.empty?

  # On (and firing) first by next due, then off.
  ordered = list.entries.reject { |schedule| schedule.state == "off" } + off
  rows = ordered.first(SCHEDULE_ROWS).map do |schedule|
    { "name" => schedule.name, "state" => state_words(schedule), "when" => schedule.recurrence_words,
      "next" => clock(schedule.next_due), "last_run" => clock(schedule.last_fired), "last_result" => schedule.last_result,
      "skips" => "#{schedule.skips}/#{schedule.max_skips}", "failures" => "#{schedule.failures}/#{schedule.max_failures}",
      "mode" => schedule.mode, "id" => schedule.id.to_s[0, 8] }
  end
  more = ordered.size - rows.size
  ui.text "Schedules#{"\n\nThe first #{SCHEDULE_ROWS}; #{more} more in `chi schedule list --all`." if more.positive?}"
  ui.table rows, columns: { "name" => "Name", "state" => "State", "when" => "When", "next" => "Next", "last_run" => "Last run",
                            "last_result" => "Last result", "skips" => "Skips", "failures" => "Failures", "mode" => "Mode",
                            "id" => "ID" },
                 key: %w[state next]

  runs = list.entries.flat_map { |schedule| schedule.history.map { |run| [schedule, run] } }
             .sort_by { |_schedule, run| run.at.to_s }.reverse
  if runs.empty?
    ui.text "Recent runs\n\nNo runs recorded yet."
    next
  end

  shown = runs.first(RUN_ROWS)
  ui.text "Recent runs#{"\n\nThe last #{RUN_ROWS} of #{runs.size}; `chi schedule show ID` has each one's." if runs.size > RUN_ROWS}"
  ui.table shown.map { |schedule, run|
             { "when" => clock(run.at), "schedule" => schedule.name, "what" => run.status, "why" => run.detail,
               "session" => run.session_id&.slice(0, 8) }
           },
           columns: { "when" => "When", "schedule" => "Schedule", "what" => "What", "why" => "Why", "session" => "Session" },
           key: %w[schedule what]
end
