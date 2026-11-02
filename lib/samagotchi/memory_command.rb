# frozen_string_literal: true

require "json"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "memory_paths"
require_relative "tools/memory"
require_relative "memory_bundle/index_updater"
require_relative "memory_bundle/provenance"
require_relative "memory_usage"

module Samagotchi
  # `chi memory`: the user's side of the memories (docs/memory.md). ls lists
  # both scopes' entries from their index.md lines and files, as memory_read
  # and the prompt see them; rm removes one as memory_write remove: true does
  # (Tools::MemoryWrite.remove: the file and its model overlays into the
  # bundle trash, the index line dropped, a bundle's memory refused); usage
  # reports what the memories cost and what the saved sessions read
  # (MemoryUsage, docs/memory.md "What the memories cost").
  class MemoryCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi memory <ls|rm|usage> [options]
        ls [--scope project|system] [--format text|json]   the memories: both scopes (this folder's project
             first), or one; each with its size, date, the bundle it came from and its index description
        rm NAME [--scope project|system]   remove a memory: its file and its model overlays (NAME.<key>.md)
             move to the bundle trash (chi bundle trash lists and empties it) and its index line is dropped.
             Without --scope NAME must be in one scope only. A bundle's memory is refused: chi bundle
             uninstall removes it. NAME.<key> removes one model overlay alone.
        usage [--scope project|system] [--top N] [--format text|json]   what the memories cost, counted from
             the saved sessions: each scope's index tokens, the memories read most (by tokens), and the ones
             no saved session read. --top is the rows per section (10); no sessions says so and exits 0.
    TEXT

    SUBCOMMANDS = %w[ls rm usage].freeze
    SCOPES = Tools::VALID_SCOPES
    # The description column's width in ls's text form (json has it all).
    DESCRIPTION_WIDTH = 60
    # ls's size column, right-aligned.
    SIZE_COLUMN = 2
    # usage's rows per section, when --top is not given.
    DEFAULT_TOP = 10

    FLAGS = {
      "ls" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--scope"
        f.value "--format"
      end,
      "rm" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--scope" },
      "usage" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--scope"
        f.value "--top"
        f.value "--format"
      end
    }.freeze

    # One memory of a scope. +date+ is the index line's (the file's mtime
    # when it has none); +source+ the bundle that owns it; +overlays+ the
    # model keys of its overlays; +indexed+ / +file+: whether it has an
    # index line / a file (a line whose file was deleted by hand has none).
    Entry = Data.define(:name, :scope, :path, :bytes, :date, :source, :description, :overlays, :indexed, :file) do
      def to_h = super.transform_keys(&:to_s)
    end

    # A managed index line: "- **name** · scope · date · size[ · from b][ — desc]"
    # or a legacy "- **name**: desc" (MemoryWrite.managed_pattern).
    LINE = /^- \*\*([^*\n]+)\*\*[ \t]*(?:[·•][^\n]*|:[^\n]*)?$/

    # @param argv [Array<String>] the arguments after "memory"
    # The project scope is the cwd's project, as for the memory tools.
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    # @return [Integer] exit status: 0 done, 1 refused or failed, 2 usage
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return CLI::Exit::OK
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      scope = parsed.options[:scope]
      return usage_error("unknown scope #{scope.inspect}: use --scope project|system") if scope && !SCOPES.include?(scope)

      send(:"run_#{@sub}", parsed.options, parsed.args)
    end

    # The memories of +scope+ (project first, then system, when nil), by
    # name within a scope.
    # @return [Array<Entry>]
    def self.entries(scope = nil)
      owners = MemoryBundle::Provenance.each_installed.reject { |_, bundle| bundle.error? }
      (scope ? [scope] : SCOPES).flat_map { |s| scope_entries(s, owners) }
    end

    def self.scope_entries(scope, owners)
      dir = MemoryPaths.scope_dir(scope)
      return [] unless File.directory?(dir)

      index_path = File.join(dir, "#{Tools::MEMORY_INDEX}.md")
      index_text = File.file?(index_path) ? File.read(index_path, encoding: "UTF-8") : ""
      # name => its line; the first one when a name has two. A name rm
      # would refuse (a path: "../x") isn't listed.
      lines = {}
      index_text.each_line do |l|
        (m = l.chomp.match(LINE)) or next
        lines[m[1]] ||= m[0] unless Tools::MemoryRead.invalid_name?(m[1])
      end
      stems = Dir.children(dir).filter_map { |f| f.delete_suffix(".md") if f.end_with?(".md") && File.file?(File.join(dir, f)) }.to_set
      overlays = overlays_by_base(stems, lines)
      overlay_stems = overlays.values.flatten(1).to_set { |_key, stem| stem }
      names = (lines.keys + stems.to_a).uniq - [Tools::MEMORY_INDEX]
      names.filter_map do |name|
        next if overlay_stems.include?(name)

        path = File.join(dir, "#{name}.md")
        line = lines[name]
        file = stems.include?(name)
        # A bold line of prose ("- **Important**") isn't a memory: only a
        # managed line ("· …") counts without a file.
        next unless file || line&.include?(" · ")

        entry(name, scope, path, line, file, overlays.fetch(name, []).map(&:first), owners)
      end.sort_by(&:name)
    end

    # base name => [[key, stem]...] of its model overlays, in one pass over
    # the files (+stems+, a Set): <base>.<key>.md with a key ModelOverlay
    # makes, whose base is a file and whose stem has no index line of its
    # own (MemoryWrite.overlay_files' rule, for every base at once).
    def self.overlays_by_base(stems, lines)
      stems.sort.each_with_object({}) do |stem, by_base|
        base, dot, key = stem.rpartition(".")
        next if dot.empty? || base.empty? || !key.match?(/\A[a-z0-9-]+\z/)
        next unless stems.include?(base) && !lines.key?(stem)

        (by_base[base] ||= []) << [key, stem]
      end
    end

    def self.entry(name, scope, path, line, file, overlay_keys, owners)
      source = line && MemoryBundle::IndexUpdater.extract_source(line)
      source ||= owners.find { |_, bundle| bundle.effective_scope == scope && bundle.owns?("#{name}.md") }&.first
      Entry.new(
        name: name, scope: scope, path: path, bytes: file ? File.size(path) : nil,
        date: line.to_s[/ · (\d{4}-\d{2}-\d{2})\b/, 1] || (file ? File.mtime(path).strftime("%Y-%m-%d") : nil),
        source: source, description: line && line.include?(" · ") ? line.split(" — ", 2)[1]&.strip : legacy(line),
        overlays: overlay_keys,
        indexed: !line.nil?, file: file
      )
    end

    # A legacy "- **name**: desc" line's description.
    def self.legacy(line) = line&.split("**:", 2)&.[](1)&.strip&.then { |d| d.empty? ? nil : d }
    private_class_method :scope_entries, :overlays_by_base, :entry, :legacy

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi memory #{@sub}" : "chi memory"
    def usage_on_error = nil

    def run_ls(options, args)
      return usage_error("ls takes no NAME (unexpected #{args.first})") unless args.empty?

      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      rows = self.class.entries(options[:scope])
      if format == "json"
        @stdout.puts(JSON.pretty_generate(rows.map(&:to_h)))
      elsif rows.empty?
        @stdout.puts("no memories#{" in #{options[:scope]} scope" if options[:scope]}")
      else
        print_rows(rows)
      end
      CLI::Exit::OK
    end

    def print_rows(rows)
      table = rows.map do |r|
        notes = []
        notes << "overlays: #{r.overlays.join(", ")}" unless r.overlays.empty?
        notes << "no file" unless r.file
        notes << "no index line" unless r.indexed
        [r.scope, r.name, r.bytes.to_s, r.date.to_s, r.source ? "from #{r.source}" : "",
         [clip(r.description.to_s), *notes.map { |n| "[#{n}]" }].reject(&:empty?).join(" ")]
      end
      widths = table.transpose.map { |column| column.map(&:length).max }
      # A column no row fills (no memory from a bundle) takes no room.
      table.each do |line|
        cells = line.each_with_index.map { |cell, i| i == SIZE_COLUMN ? cell.rjust(widths[i]) : cell.ljust(widths[i]) }
        @stdout.puts(cells.reject.with_index { |_, i| widths[i].zero? }.join("  ").rstrip)
      end
    end

    def clip(text) = text.length > DESCRIPTION_WIDTH ? "#{text[0, DESCRIPTION_WIDTH - 1]}…" : text

    def run_usage(options, args)
      return usage_error("usage takes no NAME (unexpected #{args.first})") unless args.empty?

      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)
      return usage_error("--top must be a positive integer") unless options[:top].nil? || options[:top].to_s.match?(/\A[1-9]\d*\z/)

      sessions, unreadable = MemoryUsage.load_sessions
      report = MemoryUsage.new(
        sessions: sessions, entries: self.class.entries(options[:scope]),
        scopes: options[:scope] ? [options[:scope]] : SCOPES, unreadable: unreadable, root: Dir.pwd,
        baseline: ConfigFile.preloaded_memories
      ).report(top: (options[:top] || DEFAULT_TOP).to_i)

      if format == "json"
        @stdout.puts(JSON.pretty_generate(report.to_h))
      else
        print_usage(report)
      end
      CLI::Exit::OK
    end

    def print_usage(report)
      if report.sessions.zero?
        @stdout.puts("no sessions to count: nothing saved in #{Session.default_state_dir}")
        return
      end

      header = "#{report.sessions} #{report.sessions == 1 ? "session" : "sessions"} over " \
               "#{report.days} #{report.days == 1 ? "day" : "days"}"
      header += ", #{report.unreadable} unreadable #{report.unreadable == 1 ? "file" : "files"} skipped" if report.unreadable.positive?
      @stdout.puts(header)
      @stdout.puts

      # The index comes first: it is paid on every prompt, reads only on a read.
      print_table(["Indexes", "tokens", "limit", "index lines naming a memory no session read"],
                  report.indexes.map do |index|
                    [indent(index.scope), token_text(index.tokens), index.limit.positive? ? index.limit.to_s : "off",
                     "#{index.unread_lines} of #{index.lines} (#{index.unread_percent}%)"]
                  end, right: [1, 2])
      @stdout.puts

      if report.read_count.zero?
        @stdout.puts("No memory reads in these sessions.")
      else
        share = report.read_tokens.positive? ? (100.0 * report.top.sum(&:tokens) / report.read_tokens).round : 0
        @stdout.puts("Most read, by tokens (these #{report.top.size} of #{report.read_names}: " \
                     "#{share}% of #{token_text(report.read_tokens)} read tokens)")
        print_table(%w[Memory tokens reads size scope from],
                    report.top.map do |use|
                      [indent(use.name), token_text(use.tokens), use.reads.to_s,
                       use.size_tokens ? token_text(use.size_tokens) : "-", use.scope, use.source.to_s]
                    end, right: [1, 2])
        if report.cut_reads.positive?
          @stdout.puts(indent("note: #{report.cut_reads} of these reads came back cut (reads used to be cut), " \
                              "so a big memory may cost more per read now than these numbers show"))
        end
      end
      @stdout.puts

      if report.not_read_total.zero?
        @stdout.puts("Not read in saved sessions: nothing of your own to count (a bundle's memories are not listed)")
      else
        @stdout.puts("Not read in saved sessions: #{report.not_read_count} of #{report.not_read_total} of your own " \
                     "memories (a bundle's are not listed)")
        print_table(["", "size", "scope"], report.not_read.map { |entry| [indent(entry.name), token_text(entry.tokens), entry.scope] }, right: [1]) if report.not_read.any?
        @stdout.puts(indent("An index line is paid whatever a session reads: a memory nobody opens still costs its line in every prompt."))
      end

      @stdout.puts(indent("Names read that have no memory now: #{report.unknown_names}")) if report.unknown_names.positive?
    end

    def indent(text) = "  #{text}"

    # A token count as usage's columns show it: "450", "1.9k", "2.0M".
    def token_text(value)
      number = value.to_i
      return number.to_s if number < 1000
      return format("%.1fk", number / 1000.0) if number < 1_000_000

      format("%.1fM", number / 1_000_000.0)
    end

    # A header row and its rows, two spaces apart; the +right+ columns align on
    # their numbers.
    def print_table(header, rows, right: [])
      table = [header, *rows]
      widths = table.transpose.map { |column| column.map { |cell| cell.to_s.length }.max }
      table.each do |cells|
        line = cells.each_with_index.map do |cell, index|
          right.include?(index) ? cell.to_s.rjust(widths[index]) : cell.to_s.ljust(widths[index])
        end
        @stdout.puts(line.reject.with_index { |_, index| widths[index].zero? }.join("  ").rstrip)
      end
    end

    def run_rm(options, args)
      name = args.shift
      return usage_error("give the memory's NAME") unless name
      return usage_error("rm takes one NAME (unexpected #{args.first})") unless args.empty?

      scope = options[:scope] || only_scope(name)
      return scope if scope.is_a?(Integer)

      result = Tools::MemoryWrite.call(nil, path: name, scope: scope, remove: true)
      if result.start_with?("Error: ")
        error_line("#{command_name}: #{result.delete_prefix("Error: ")}")
        return CLI::Exit::FAILED
      end

      @stdout.puts(result)
      CLI::Exit::OK
    end

    # The one scope +name+ is in (a file or an index line), else the exit
    # status: a usage error when it is in both, a failure in neither (an
    # invalid name goes on to remove's own error).
    # @return [String, Integer]
    def only_scope(name)
      return "project" if Tools::MemoryRead.invalid_name?(name) || name == Tools::MEMORY_INDEX

      found = SCOPES.select { |scope| present?(name, scope) }
      case found.size
      when 1 then found.first
      when 0
        error_line("#{command_name}: no memory '#{name}' in project or system scope")
        CLI::Exit::FAILED
      else
        usage_error("#{name} is in both scopes: chi memory rm #{name} --scope project, or --scope system")
      end
    end

    def present?(name, scope)
      dir = MemoryPaths.scope_dir(scope)
      index = File.join(dir, "#{Tools::MEMORY_INDEX}.md")
      File.file?(File.join(dir, "#{name}.md")) ||
        (File.file?(index) && File.read(index, encoding: "UTF-8").match?(Tools::MemoryWrite.managed_pattern(name)))
    end
  end
end
