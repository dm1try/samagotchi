# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "session"
require_relative "system_one/runs"

module Samagotchi
  # `chi judgments`: what System 1's saved runs hold (docs/system-one.md).
  # Reads only: it never asks a model or changes a run.
  class JudgmentsCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi judgments ls
             chi judgments report NAME [--days N]
        System 1's saved asks on this machine. ls: each judgment's digests,
        runs, labels, failures, models and size. report: one judgment's counts,
        p histogram and labels by value, over N days (default: all that's kept).
    TEXT

    SUBCOMMANDS = %w[ls report].freeze
    FLAGS = { "ls" => CLI::Flags.new(args: false), "report" => CLI::Flags.new { |flags| flags.value "--days" } }.freeze
    BINS = 10

    # @param argv [Array<String>] the arguments after "judgments"
    # @param sessions_dir [String, nil] the sessions folder (a spec seam)
    # @param now [Time] the report's clock (a spec seam)
    def initialize(argv, stdout: $stdout, stderr: $stderr, sessions_dir: nil, now: Time.now)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @store = SystemOne::RunsStore.new(File.dirname(sessions_dir || Session.default_state_dir))
      @now = now
    end

    def run
      @sub = @argv.first
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return CLI::Exit::OK
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      @sub == "ls" ? ls : report(parsed)
    end

    private

    def command_name = @sub ? "chi judgments #{@sub}" : "chi judgments"

    def ls
      names = @store.names
      if names.empty?
        @stdout.puts("No saved runs.")
        return CLI::Exit::OK
      end

      names.each { |name| @stdout.puts(ls_line(name)) }
      CLI::Exit::OK
    end

    def ls_line(name)
      runs, later = @store.lines(name).partition { |line| line["kind"] == "run" }
      models = runs.filter_map { |run| run["served_model"] || run["model"] }.uniq
      "#{name}  digests #{@store.versions(name).size}  runs #{runs.size}  " \
        "labels #{last_labels(runs, later).size}  failures #{runs.count { |run| run["failure"] }}  " \
        "models #{models.empty? ? "none" : models.join(", ")}  #{size_text(@store.size(name))}"
    end

    def size_text(bytes)
      return "#{bytes} B" if bytes < 1024
      return format("%.1f KB", bytes / 1024.0) if bytes < 1024 * 1024

      format("%.1f MB", bytes / (1024.0 * 1024))
    end

    def report(parsed)
      name = parsed.args.first
      return usage_error("report takes one judgment's name (see chi judgments ls)") if parsed.args.size != 1
      return usage_error("not a judgment's name: #{name}") unless name.match?(SystemOne::RunsStore::NAME)

      days = parsed.options[:days]
      return usage_error("--days takes a positive whole number") if days && !days.to_s.match?(/\A[1-9]\d*\z/)

      since = days && (@now.utc - (Integer(days, 10) * 86_400)).strftime("%F")
      runs, later = @store.lines(name).partition { |line| line["kind"] == "run" }
      runs = runs.select { |run| since.nil? || run["at"].to_s[0, 10] >= since }
      if runs.empty?
        @stdout.puts("No runs of #{name}#{" in the last #{days} days" if days}.")
        return CLI::Exit::OK
      end

      print_report(name, days, runs, later)
      CLI::Exit::OK
    end

    def print_report(name, days, runs, later)
      @stdout.puts("#{name} · #{days ? "last #{days} days" : "all kept"}")
      asked = runs.count { |run| run["asked"] != false }
      @stdout.puts("runs #{runs.size}  asked #{asked}  skipped #{runs.size - asked}  failures #{runs.count { |run| run["failure"] }}  " \
                   "truncated #{runs.count { |run| run["truncated"] }}  test runs #{runs.count { |run| run["test_run"] }}")
      failures = tally(runs.filter_map { |run| run["failure"] })
      @stdout.puts("failures by class: #{failures}") unless failures.empty?
      print_answers(runs)
      last = last_labels(runs, later)
      ids = runs.to_h { |run| [run["id"], true] }
      @stdout.puts("labels: #{last.empty? ? "none" : tally(last.map { |line| "#{line["value"]} (#{line["by"]})" })}")
      acted = later.select { |line| line["kind"] == "acted" && ids[line["run_id"]] }
      @stdout.puts("acted: #{tally(acted.map { |line| line["what"] })}") unless acted.empty?
    end

    # One label per run and question: the last said. One whose run is gone
    # or out of the window doesn't count.
    def last_labels(runs, later)
      ids = runs.to_h { |run| [run["id"], true] }
      labels = later.select { |line| line["kind"] == "label" && ids[line["run_id"]] }
      labels.to_h { |line| [[line["run_id"], line["question"]], line] }.values
    end

    def print_answers(runs)
      answers = runs.flat_map { |run| (run["answers"].is_a?(Hash) ? run["answers"] : {}).to_a }
      answers.group_by(&:first).sort.each do |question, pairs|
        values = pairs.map(&:last).grep(Hash)
        probabilities = values.filter_map { |answer| answer["noul"] || answer["confidence"] }.grep(Numeric).select { |p| p.between?(0, 1) }
        kind = values.first&.fetch("type", nil)
        @stdout.puts("#{question} (#{kind}): #{probabilities.size} with a p#{", picks #{picks(values)}" if picks(values)}")
        histogram(probabilities).each { |line| @stdout.puts("  #{line}") }
      end
    end

    def picks(values)
      chosen = values.filter_map { |answer| answer["choice"] }
      chosen.empty? ? nil : tally(chosen)
    end

    def histogram(values)
      return [] if values.empty?

      counts = Array.new(BINS, 0)
      values.each { |value| counts[[(value.to_f * BINS).floor, BINS - 1].min] += 1 }
      counts.each_with_index.map do |count, bin|
        format("%.1f–%.1f %5d", bin.to_f / BINS, (bin + 1).to_f / BINS, count)
      end
    end

    def tally(values)
      values.tally.sort_by { |value, count| [-count, value.to_s] }.map { |value, count| "#{value} #{count}" }.join(", ")
    end
  end
end
