# frozen_string_literal: true

require "json"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "message_time"
require_relative "pages"
require_relative "pages/store"
require_relative "pages/launch"

module Samagotchi
  # `chi page`: run, list and remove pages (docs/pages.md). run goes through
  # Pages::Launch, the one launch path chi web's Refresh takes too, and
  # prints what a model needs to check its own work: per block a few lines,
  # a table's labels, first rows and total, formatted as the page shows them.
  class PageCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi page <run|list|rm> [options]
        run NAME [--format text|json]   run ~/.config/samagotchi/pages/NAME.rb in a process of its own (in the
             pages folder, cut at #{Pages::TIMEOUT_SECONDS} s with what it started), store what it built and print a summary of
             each block (json: the stored page). A failed run keeps the last good result. Exit 1 when the
             script raised, was stopped or broke a limit, when there is no such page or it is already running.
        list [--format text|json]   every page: its title, when it last ran or failed (and on which line),
             (never ran), and "changed" when the script changed since the result was made
        rm NAME   remove a page: its script and its stored result
    TEXT

    SUBCOMMANDS = %w[run list rm].freeze

    FLAGS = {
      "run" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "list" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "rm" => CLI::Flags.new(help: HELP_WORDS)
    }.freeze

    # How much of a run's summary each block gets.
    TEXT_LINES = 3
    TEXT_CHARS = 240
    TABLE_ROWS = 3
    STDERR_LINES = 10
    BLANK = "—"

    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    # @return [Integer] 0 done, 1 failed (the script, no such page, busy), 2 usage
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return CLI::Exit::OK
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      send(:"run_#{@sub}", parsed.options, parsed.args)
    rescue Pages::BadName => e
      usage_error(e.message)
    rescue Pages::Missing, Pages::Busy => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    rescue Interrupt
      CLI::Exit::INTERRUPTED
    end

    # The summary's form of a cell: :money as $0.0000, :count as 1.2k / 3.4M,
    # nil as —, anything else as it is.
    def self.cell(value, format)
      return BLANK if value.nil?
      return value.to_s unless value.is_a?(Numeric)

      case format
      when "money" then Kernel.format("$%.4f", value)
      when "count" then count(value)
      else value.to_s
      end
    end

    def self.count(value)
      size = value.abs
      return value.to_s if size < 1000

      text, unit = size < 1_000_000 ? [value / 1000.0, "k"] : [value / 1_000_000.0, "M"]
      "#{Kernel.format("%.1f", text).delete_suffix(".0")}#{unit}"
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi page #{@sub}" : "chi page"
    def usage_on_error = nil

    def one_name(args)
      return usage_error("give the page's NAME") if args.empty?
      return usage_error("#{@sub} takes one NAME (unexpected #{args[1]})") if args.size > 1

      Pages.check_name!(args.first)
    end

    def run_run(options, args)
      format = options[:format]
      refused = format_refusal(format)
      return refused if refused

      name = one_name(args)
      return name if name.is_a?(Integer)

      result = Pages::Launch.run(name)
      if format == "json"
        @stdout.puts(JSON.generate(result.page.to_json_hash))
      elsif result.ok?
        print_summary(result)
      else
        print_failure(result)
      end
      result.ok? ? CLI::Exit::OK : CLI::Exit::FAILED
    end

    def print_summary(result)
      page = result.page
      @stdout.puts(%(page #{page.name}: #{page.title.inspect} (#{Kernel.format("%.1f", result.seconds)} s)))
      page.blocks.each { |block| summary(block).each { |line| @stdout.puts(line) } }
    end

    def summary(block)
      case block["type"]
      when "text" then text_summary(block["text"].to_s)
      when "table" then table_summary(block)
      when "walk" then [%(- walk: #{block.dig("data", "title").to_s.inspect}, #{Array(block.dig("data", "steps")).size} steps)]
      else ["- #{block["type"]}"]
      end
    end

    def text_summary(text)
      lines = text.lines.map(&:chomp)
      shown = lines.first(TEXT_LINES).join("\n")
      cut = lines.size > TEXT_LINES || shown.size > TEXT_CHARS
      shown = shown[0, TEXT_CHARS]
      first, *rest = shown.split("\n", -1)
      ["- text: #{first}#{" …" if cut && rest.empty?}", *rest.each_with_index.map do |line, i|
        "    #{line}#{" …" if cut && i == rest.size - 1}"
      end]
    end

    def table_summary(block)
      columns = Array(block["columns"])
      rows = Array(block["rows"])
      dropped = block["dropped"].to_i
      head = "- table, #{rows.size} rows#{" (#{dropped} dropped)" unless dropped.zero?}, columns: " \
             "#{columns.map { |c| c["label"] }.join(", ")}"
      line = ->(cells) { columns.each_with_index.map { |c, i| self.class.cell(cells[i], c["format"]) }.join(" | ") }
      [head, *rows.first(TABLE_ROWS).map { |cells| "    #{line.call(cells)}" },
       *("    total: #{line.call(block["total"])}" if block["total"])]
    end

    def print_failure(result)
      page = result.page
      error = page.error
      @stdout.flush
      @stderr.puts("error: #{"line #{error.line}: " if error&.line}#{error&.message}")
      result.stderr.lines.map(&:chomp).reject(&:empty?).last(STDERR_LINES).each { |line| @stderr.puts("  #{line}") }
      @stderr.puts("the result of #{local(page.ran_at)} is kept") if page.ran_at
    end

    def run_list(options, args)
      return usage_error("list takes no NAME (unexpected #{args.first})") unless args.empty?

      format = options[:format]
      refused = format_refusal(format)
      return refused if refused

      pages = Pages::Store.list
      if format == "json"
        @stdout.puts(JSON.generate(pages.map do |page|
          page.to_json_hash.except("blocks").merge("state" => page.state.to_s, "changed" => page.changed?)
        end))
      elsif pages.empty?
        @stdout.puts("no pages (a page is a script at #{Paths.tilde(Pages.scripts_dir)}/NAME.rb)")
      else
        print_list(pages)
      end
      CLI::Exit::OK
    end

    def print_list(pages)
      table = pages.map do |page|
        title = page.state == :never_ran ? "(never ran)" : page.title.to_s
        [page.name, title, [status(page), ("changed" if page.changed?)].compact.join(", ")]
      end
      widths = table.transpose.map { |column| column.map(&:length).max }
      table.each do |row|
        @stdout.puts(row.each_with_index.map { |cell, i| i == row.size - 1 ? cell : cell.ljust(widths[i]) }.join("  ").rstrip)
      end
    end

    def status(page)
      case page.state
      when :ok then "ran #{ago(page.ran_at)}"
      when :failed then "failed #{ago(page.error.at)}#{" (line #{page.error.line})" if page.error.line}"
      else ""
      end
    end

    def ago(iso)
      seconds = Time.now - Time.iso8601(iso.to_s)
      seconds < 60 ? "#{[seconds.round, 0].max} s ago" : "#{MessageTime.ago(seconds)} ago"
    rescue ArgumentError
      "at #{iso}"
    end

    def local(iso)
      Time.iso8601(iso.to_s).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      iso.to_s
    end

    def run_rm(_options, args)
      name = one_name(args)
      return name if name.is_a?(Integer)

      Pages::Store.remove(name)
      @stdout.puts("removed page #{name}")
      CLI::Exit::OK
    end
  end
end
