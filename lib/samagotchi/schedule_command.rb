# frozen_string_literal: true

require "json"
require "time"

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "schedule_display"
require_relative "schedules"
require_relative "session"

module Samagotchi
  # `chi schedule`: durable schedules that outlive every worker (docs/scheduling.md).
  # A tick run by cron, systemd or chi web's hub (`chi schedule tick`) fires the
  # entries whose time has come against a session: the next link of its chain
  # (the default), or a queued turn in the session itself.
  # bin/chi dispatches here before OptionParser; this machine only.
  class ScheduleCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi schedule <add|edit|list|show|tick|run-now|enable|disable|cancel> [flags]

        add --session ID (--continues ID) (-m|--message|--prompt TEXT) [--title TEXT]
            one of: --every 30m | --weekday 1 --time 09:00 | --date 2026-11-20T09:00
            [--mode chain|same] [--catch-up once|none] [--keep-links N] [--max-failures N] [--max-skips N]
            [--if CMD]
        edit ID [--title TEXT] [-m|--prompt TEXT] [one recurrence, whole, as add's]
            [--catch-up once|none] [--keep-links N] [--max-failures N] [--max-skips N] [--if CMD | --no-if]
            only the flags given change; the session and mode stay (cancel and add for those);
            a spent --date one-off stays disabled (enable it)
        list [--all] [--format text|json]
        show ID
        tick [--dry-run] [--format text|json]
        run-now ID
        enable ID | disable ID | cancel ID

      Recurrence: --every 45m / 2h / 1d (UTC interval math: an `every 1d` schedule drifts
      an hour across a DST change — use --weekday for a wall-clock time);
      --weekday 1..7 (1=Mon) with --time HH:MM in the machine's local zone;
      --date one local moment.
      Modes: chain (default) runs the prompt as the next link of the session's chain;
      same queues it as a turn in the session itself.
      A busy target is skipped and retried at the next tick; after max_skips skips
      (default 12) or max_failures failures (default 3) the schedule is disabled.
      --if CMD: the tick runs CMD in the session's folder first; exit 0 fires, 1..125
      skips this occurrence quietly ("not needed"), anything else is a failure. From
      your own terminal only (not inside a chi session); run-now doesn't run it.
    TEXT

    SUBCOMMANDS = %w[add edit list show tick run-now enable disable cancel].freeze

    # A usage error names the subcommand it was given (CLI::Command's
    # usage_error builds its line from this).
    def command_name = SUBCOMMANDS.include?(@argv.first.to_s) ? "chi schedule #{@argv.first}" : "chi schedule"

    # The flags that set a schedule's fields (add's, and the ones edit changes).
    FIELD_FLAGS = lambda do |f|
      f.value "-m", "--message", "--prompt", key: :prompt
      f.value "--title"
      f.value "--every"
      f.value "--weekday"
      f.value "--time"
      f.value "--date"
      f.value "--catch-up"
      f.value "--keep-links"
      f.value "--max-failures"
      f.value "--max-skips"
    end

    FLAGS = {
      "add" => CLI::Flags.new(args: true) do |f|
        f.value "--session", "--continues", key: :target
        f.value "--mode"
        FIELD_FLAGS.call(f)
        f.value "--if", key: :condition
      end,
      "edit" => CLI::Flags.new(args: true) do |f|
        FIELD_FLAGS.call(f)
        f.value "--if", key: :condition
        f.switch "--no-if"
        f.refuse "--session", "--continues", "--mode", "edit can't change the session or mode: cancel it and add a new one"
      end,
      "list" => CLI::Flags.new(args: false) do |f|
        f.switch "--all", key: :include_disabled
        f.value "--format"
      end,
      "show" => CLI::Flags.new(args: true),
      "tick" => CLI::Flags.new(args: false) do |f|
        f.switch "--dry-run"
        f.value "--format"
      end,
      "run-now" => CLI::Flags.new(args: true),
      "enable" => CLI::Flags.new(args: true),
      "disable" => CLI::Flags.new(args: true),
      "cancel" => CLI::Flags.new(args: true)
    }.freeze

    # @param argv [Array<String>] the arguments after "schedule"
    # A condition runs unattended, outside the guardrails: never set from
    # inside a chi session (an agent), as chi broadcast refuses there too.
    CONDITION_IN_SESSION = "a schedule's condition is set only from your own terminal (chi schedule … --if), " \
                           "not from inside a chi session"
    # The older chis that would fire a condition entry unchecked hide it
    # instead (Schedules::ConditionPart): the line add and edit print.
    CONDITION_TICKERS = "every chi that ticks (chi web, cron) must be newer than 0.188.0; " \
                        "an older one leaves this schedule alone"

    # @param schedules [Schedules, nil] the store; default this machine's
    # @param env [Hash] SAMAGOTCHI_PARENT_SESSION set: run inside a session
    def initialize(argv, stdout: $stdout, stderr: $stderr, schedules: nil, env: ENV)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @schedules = schedules || Schedules.new
      @env = env
    end

    # @return [Integer] exit status: 0 ok, 1 a missing session or schedule,
    #   2 a usage error
    def run
      sub = @argv[0]
      if sub.nil? || HELP_WORDS.include?(sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{sub}") unless SUBCOMMANDS.include?(sub)

      parsed = parse_flags(FLAGS.fetch(sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      @opts = parsed.options
      @args = parsed.args
      if @opts.key?(:condition) || @opts[:no_if]
        unless @env["SAMAGOTCHI_PARENT_SESSION"].to_s.empty?
          error_line("#{command_name}: #{CONDITION_IN_SESSION}")
          return CLI::Exit::USAGE
        end
        return usage_error("--if and --no-if together: give one") if @opts.key?(:condition) && @opts[:no_if]
      end

      case sub
      when "add" then add
      when "edit" then edit
      when "list" then list
      when "show" then show
      when "tick" then tick
      when "run-now" then act { |id| @schedules.run_now(id) }
      when "enable" then act { |id| @schedules.enable(id) }
      when "disable" then act { |id| @schedules.disable(id) }
      when "cancel" then act { |id| @schedules.cancel(id) }
      end
    end

    private

    def add
      if @opts[:target].to_s.strip.empty? && !@args.empty?
        return usage_error("add takes the session with --session ID, not #{@args.map { |arg| arg.inspect }.join(" ")}")
      end
      return usage_error("add needs --session ID (the session the schedule runs against)") if @opts[:target].to_s.strip.empty?
      return usage_error("add needs a prompt: -m \"...\"") if @opts[:prompt].to_s.strip.empty?

      begin
        recurrence = Schedules.recurrence(every: @opts[:every], weekday: @opts[:weekday], time: @opts[:time], date: @opts[:date])
        entry = @schedules.add(target: @opts[:target], prompt: @opts[:prompt], recurrence: recurrence,
                               title: @opts[:title], mode: @opts[:mode] || Schedules::CHAIN,
                               catch_up: @opts[:catch_up], keep_links: @opts[:keep_links],
                               max_failures: @opts[:max_failures], max_skips: @opts[:max_skips],
                               condition: @opts[:condition])
      rescue Schedules::Usage => e
        return usage_error(e.message)
      rescue Session::AmbiguousId => e
        return failed("which session? #{e.message}")
      rescue Session::NotFound
        return failed("no session #{@opts[:target]}")
      end

      @stdout.puts("#{entry.id} added: #{entry.target_words} · #{entry.recurrence_words}#{condition_words(entry)} · " \
                   "next #{clock(entry.next_due)}")
      @stdout.puts(CONDITION_TICKERS) if entry.condition
      print_tick_warning
      CLI::Exit::OK
    end

    # Only the flags given change; a recurrence is given whole (--time alone
    # is refused as add refuses it).
    def edit
      id = @args.first
      return usage_error("edit needs a schedule id") if id.to_s.strip.empty?

      recurrence = if %i[every weekday time date].any? { |key| @opts.key?(key) }
                     Schedules.recurrence(every: @opts[:every], weekday: @opts[:weekday], time: @opts[:time], date: @opts[:date])
                   end
      condition = @opts[:no_if] ? :none : @opts[:condition]
      entry = @schedules.edit(id, title: @opts[:title], prompt: @opts[:prompt], recurrence: recurrence,
                                  catch_up: @opts[:catch_up], keep_links: @opts[:keep_links],
                                  max_failures: @opts[:max_failures], max_skips: @opts[:max_skips], condition: condition)
      return failed("no schedule #{id}") if entry.nil?

      @stdout.puts(entry_line(entry))
      @stdout.puts(CONDITION_TICKERS) if @opts.key?(:condition)
      CLI::Exit::OK
    rescue Schedules::EditPart::InFlight => e
      failed(e.message)
    rescue Schedules::Usage => e
      usage_error(e.message)
    end

    def list
      refused = format_refusal(@opts[:format])
      return refused if refused

      entries = @schedules.entries(include_disabled: @opts[:include_disabled] ? true : false)
      if @opts[:format] == "json"
        @stdout.puts(JSON.pretty_generate(entries.map { |entry| entry_line_json(entry) }))
        print_tick_warning(@stderr)
        return CLI::Exit::OK
      end
      if entries.empty?
        @stdout.puts("no schedules")
        print_tick_warning
        return CLI::Exit::OK
      end
      name_width = ScheduleDisplay.name_width(entries)
      entries.each { |entry| @stdout.puts(entry_line(entry, name_width: name_width)) }
      print_tick_warning
      CLI::Exit::OK
    end

    def show
      id = @args.first || @opts[:id]
      return usage_error("show needs a schedule id") if id.to_s.strip.empty?

      entry = @schedules.lookup(id)
      return failed("no schedule #{id}") if entry.nil?

      @stdout.puts("#{entry.id}  #{entry.title || "(untitled)"}")
      @stdout.puts("  anchor: #{entry.anchor}  head: #{entry.head}  mode: #{entry.mode}")
      @stdout.puts("  recurrence: #{entry.recurrence_words}  next due: #{clock(entry.next_due)}")
      @stdout.puts("  last fired: #{clock(entry.last_fired)}  last result: #{entry.last_result || "-"}")
      @stdout.puts("  skips: #{entry.skips} of #{entry.max_skips}  failures: #{entry.failures} of #{entry.max_failures}")
      @stdout.puts("  keep_links: #{entry.keep_links}  enabled: #{entry.enabled}")
      @stdout.puts("  if: #{condition_show(entry)}") unless entry.condition.nil?
      @stdout.puts("  prompt: #{entry.prompt}")
      print_history(entry)
      CLI::Exit::OK
    rescue Schedules::Usage => e
      usage_error(e.message)
    end

    # The last outcomes (Schedules::HistoryPart), newest first: when, what,
    # why, and the session it acted on.
    def print_history(entry)
      return @stdout.puts("  history: -") if entry.history.empty?

      @stdout.puts("  history (newest first):")
      entry.history.reverse_each do |row|
        line = [clock(row[:at]), row[:status], row[:detail], row[:session_id]&.slice(0, 8)].compact.reject { |part| part.to_s.empty? }
        @stdout.puts("    #{line.join("  ")}")
      end
    end

    def tick
      refused = format_refusal(@opts[:format])
      return refused if refused

      result = @schedules.tick(dry_run: @opts[:dry_run] ? true : false)
      if @opts[:format] == "json"
        outcomes = result.outcomes.map do |outcome|
          line = { "id" => outcome.id, "status" => outcome.status, "detail" => outcome.detail }
          outcome.disabled ? line.merge("disabled" => true) : line
        end
        @stdout.puts(JSON.pretty_generate({ "locked" => result.locked, "outcomes" => outcomes }))
        return CLI::Exit::OK
      end

      if result.locked
        @stdout.puts("no schedules due (another tick holds the lock)")
        return CLI::Exit::OK
      end
      if result.outcomes.empty?
        @stdout.puts("no schedules due")
        return CLI::Exit::OK
      end

      result.outcomes.each do |outcome|
        word = outcome.status == "dry" ? "would fire" : outcome.status
        @stdout.puts("#{outcome.id}  #{word}  #{outcome.detail}#{" (disabled)" if outcome.disabled}")
      end
      CLI::Exit::OK
    rescue Schedules::Corrupt => e
      failed("#{e.message.lines.first.chomp}; left as is")
    end

    def act
      id = @args.first
      return usage_error("#{@argv[0]} needs a schedule id") if id.to_s.strip.empty?

      result = yield(id)
      return failed("no schedule #{id}") if result.nil?

      if result.is_a?(Schedules::Outcome)
        @stdout.puts("#{id}: #{result.status} · #{result.detail}#{" (disabled)" if result.disabled}")
        return result.status == "failed" ? CLI::Exit::FAILED : CLI::Exit::OK
      end

      @stdout.puts("#{id} #{@argv[0]}: ok")
      CLI::Exit::OK
    rescue Schedules::Usage => e
      usage_error(e.message)
    end

    def failed(message)
      error_line(message)
      CLI::Exit::FAILED
    end

    def clock(iso)
      return "-" if iso.nil? || iso.to_s.empty?

      Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      iso.to_s
    end

    # One `list` row: id, name, mode, recurrence, next due, target head, and the
    # notes (skips, why it is disabled, the last result). +name_width+ is the
    # widest name among the rows printed; without it the name column is just
    # the name. "disabled after N" only when that budget is spent: a one-off
    # whose firing failed (ScheduleDisplay.off_reason "failures") reads
    # " disabled" here.
    def entry_line(entry, name_width: nil)
      note = ""
      note += " skips #{entry.skips} of #{entry.max_skips} (#{ScheduleDisplay.skip_window(entry)})" if entry.skips.positive?
      note += off_note(entry) unless entry.enabled
      note += " if: #{ScheduleDisplay.condition_words(entry, chars: ScheduleDisplay::PROMPT_CHARS)}" unless entry.condition.nil?
      note += " last: #{entry.last_result}" if entry.last_result
      "#{entry.id}  #{ScheduleDisplay.name(entry, width: name_width)}  #{entry.mode}  #{entry.recurrence_words}  " \
        "#{clock(entry.next_due)}  #{entry.head[0, 8]}#{note}"
    end

    # " · if CMD" for add's line, "" without a condition.
    def condition_words(entry) = entry.condition.nil? ? "" : " · if #{ScheduleDisplay.condition_words(entry)}"

    # show's: the command, who set it and when, and what holds for it.
    def condition_show(entry)
      condition = entry.condition
      return ScheduleDisplay.condition_words(entry) unless condition.is_a?(Hash) && condition[:cmd].is_a?(String)

      by = condition[:by] == Schedules::ConditionPart::CONDITION_BY ? "the CLI" : condition[:by].inspect
      "#{condition[:cmd]}  (set from #{by} #{clock(condition[:set_at])}; timeout #{@schedules.condition_timeout_seconds} s; " \
        "run-now skips it)"
    end

    def off_note(entry)
      case ScheduleDisplay.off_reason(entry)
      when "skips"
        return " disabled" unless entry.skips >= entry.max_skips

        " disabled after #{entry.skips} #{entry.skips == 1 ? "skip" : "skips"}"
      when "failures"
        return " disabled" unless entry.failures >= entry.max_failures

        " disabled after #{entry.failures} #{entry.failures == 1 ? "failure" : "failures"}"
      else " disabled"
      end
    end

    def entry_line_json(entry) = ScheduleDisplay.json(entry)

    def print_tick_warning(stream = @stdout)
      warning = @schedules.tick_warning
      stream.puts(warning) if warning
    end
  end
end
