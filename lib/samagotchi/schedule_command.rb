# frozen_string_literal: true

require "json"
require "time"

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
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
      Usage: chi schedule <add|list|show|tick|run-now|enable|disable|cancel> [flags]

        add --session ID (--continues ID) (-m|--message|--prompt TEXT) [--title TEXT]
            one of: --every 30m | --weekday 1 --time 09:00 | --date 2026-11-20T09:00
            [--mode chain|same] [--catch-up once|none] [--keep-links N] [--max-failures N] [--max-skips N]
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
    TEXT

    SUBCOMMANDS = %w[add list show tick run-now enable disable cancel].freeze

    FLAGS = {
      "add" => CLI::Flags.new(args: false) do |f|
        f.value "--session", "--continues", key: :target
        f.value "-m", "--message", "--prompt", key: :prompt
        f.value "--title"
        f.value "--every"
        f.value "--weekday"
        f.value "--time"
        f.value "--date"
        f.value "--mode"
        f.value "--catch-up"
        f.value "--keep-links"
        f.value "--max-failures"
        f.value "--max-skips"
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
    # @param schedules [Schedules, nil] the store; default this machine's
    def initialize(argv, stdout: $stdout, stderr: $stderr, schedules: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @schedules = schedules || Schedules.new
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

      case sub
      when "add" then add
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
                               max_failures: @opts[:max_failures], max_skips: @opts[:max_skips])
      rescue Schedules::Usage => e
        return usage_error(e.message)
      rescue Session::AmbiguousId => e
        return failed("which session? #{e.message}")
      rescue Session::NotFound
        return failed("no session #{@opts[:target]}")
      end

      @stdout.puts("#{entry.id} added: #{entry.target_words} · #{entry.recurrence_words} · next #{clock(entry.next_due)}")
      Exit::OK
    end

    def list
      entries = @schedules.entries(include_disabled: @opts[:include_disabled] ? true : false)
      if @opts[:format] == "json"
        @stdout.puts(JSON.pretty_generate(entries.map { |entry| entry_line_json(entry) }))
        return Exit::OK
      end
      if entries.empty?
        @stdout.puts("no schedules")
        return Exit::OK
      end
      entries.each { |entry| @stdout.puts(entry_line(entry)) }
      Exit::OK
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
      @stdout.puts("  prompt: #{entry.prompt}")
      Exit::OK
    end

    def tick
      result = @schedules.tick(dry_run: @opts[:dry_run] ? true : false)
      if @opts[:format] == "json"
        @stdout.puts(JSON.pretty_generate({ "locked" => result.locked, "outcomes" => result.outcomes.map { |outcome| { "id" => outcome.id, "status" => outcome.status, "detail" => outcome.detail } } }))
        return Exit::OK
      end

      if result.locked
        @stdout.puts("no schedules due (another tick holds the lock)")
        return Exit::OK
      end
      if result.outcomes.empty?
        @stdout.puts("no schedules due")
        return Exit::OK
      end

      result.outcomes.each do |outcome|
        word = outcome.status == "dry" ? "would fire" : outcome.status
        @stdout.puts("#{outcome.id}  #{word}  #{outcome.detail}")
      end
      Exit::OK
    end

    def act
      id = @args.first
      return usage_error("#{@argv[0]} needs a schedule id") if id.to_s.strip.empty?

      result = yield(id)
      return failed("no schedule #{id}") if result.nil?

      if result.is_a?(Schedules::Outcome)
        @stdout.puts("#{id}: #{result.status} · #{result.detail}")
        return result.status == "failed" ? Exit::FAILED : Exit::OK
      end

      @stdout.puts("#{id} #{@argv[0]}: ok")
      Exit::OK
    end

    def failed(message)
      error_line(message)
      Exit::FAILED
    end

    def clock(iso)
      return "-" if iso.nil? || iso.to_s.empty?

      Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      iso.to_s
    end

    def entry_line(entry)
      note = ""
      note += " skips #{entry.skips} of #{entry.max_skips} (#{skip_window(entry)})" if entry.skips.positive?
      note += " disabled after #{entry.failures} failures" unless entry.enabled
      "#{entry.id}  #{entry.mode}  #{entry.recurrence_words}  #{clock(entry.next_due)}  #{entry.head[0, 8]}#{note}"
    end

    # A skip budget as a time window: 3 of 12 at a 5 minute tick is about 1 hour
    # of patience, which is what the count really measures.
    def skip_window(entry)
      minutes = entry.max_skips * Schedules.tick_interval_minutes
      hours = minutes / 60.0
      hours >= 1 ? "≈#{(hours * 10).round / 10} h at a #{Schedules.tick_interval_minutes} min tick" : "≈#{minutes} min"
    end

    def entry_line_json(entry)
      entry.to_h.transform_keys(&:to_s).merge(
        "recurrence_words" => entry.recurrence_words,
        "skip_window" => skip_window(entry)
      )
    end
  end
end
