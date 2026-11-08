# frozen_string_literal: true

require "fileutils"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "guardrails/path_resolve"
require_relative "memory_paths"
require_relative "paths"

module Samagotchi
  # `chi project`: which project this folder is in (MemoryPaths.lookup: a
  # git repository, a folder marked with `.chi/project.yml`, or none) and
  # its project memories folder; `chi project init [DIR]` marks a folder in
  # no git repository as a project. Git wins: a repository is already the
  # project, so init writes nothing there. Machine-local
  # (SessionAccess::Contract::MACHINE).
  class ProjectCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi project [init [DIR]]
        (none)       this folder's project: how it was found (git, marker or none), its root, its
                     top and its project memories folder
        init [DIR]   make DIR (default: this folder; created when missing) a chi project: writes
                     DIR/#{MemoryPaths::MARKER}, so DIR and every subfolder share one project memories
                     folder and group their sessions. Not in a git repository (it already is the
                     project), nor $HOME or a folder above it
    TEXT

    # What init writes into the marker (P1 reads no fields).
    MARKER_TEXT = "# chi project marker: this folder is a chi project (docs/memory.md)\n"

    SUBCOMMANDS = %w[init].freeze
    FLAGS = {
      nil => CLI::Flags.new(help: HELP_WORDS, args: false),
      "init" => CLI::Flags.new(help: HELP_WORDS)
    }.freeze

    # @param cwd [String] the folder asked about (Dir.pwd)
    # @param home [String, nil] $HOME (markers at or above it are ignored)
    # @param sessions [#call, nil] () → this machine's SessionRows (for
    #   init's restart note; SessionManager.session_rows by default)
    def initialize(argv, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, env: ENV, home: default_home, sessions: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @cwd = cwd
      @env = env
      @home = home
      @sessions = sessions || lambda {
        require_relative "session_manager"
        SessionManager.session_rows
      }
    end

    # @return [Integer] 0, 1 (a refusal), 2 usage
    def run
      @sub = SUBCOMMANDS.include?(@argv.first) ? @argv.first : nil
      parsed = parse_flags(FLAGS.fetch(@sub), @sub ? @argv[1..] : @argv)
      return parsed if parsed.is_a?(Integer)

      return run_show unless @sub
      return usage_error("init takes one folder") if parsed.args.size > 1

      run_init(parsed.args.first || @cwd)
    end

    private

    def command_name = @sub ? "chi project #{@sub}" : "chi project"
    def usage_on_error = nil

    def default_home
      Dir.home
    rescue ArgumentError
      nil
    end

    def lookup(dir) = MemoryPaths.lookup(dir, home: @home)

    def run_show
      found = lookup(@cwd)
      row("kind", found.kind.to_s)
      if found.project?
        row("root", found.root)
        row("top", found.top)
      end
      row("memories", memories_line(found.root))
      notes(found).each { |note| row("note", note) }
      CLI::Exit::OK
    end

    def row(label, value) = @stdout.puts("#{label.ljust(9)}#{value}")

    def memories_line(root)
      dir = File.join(MemoryPaths.projects_dir(env: @env), MemoryPaths.key_for_root(root))
      count = memory_count(dir)
      "#{Paths.tilde(dir)}#{" (#{count} #{count == 1 ? "memory" : "memories"})" if count.positive?}"
    end

    def memory_count(dir)
      return 0 unless File.directory?(dir)

      Dir.children(dir).count { |name| name.end_with?(".md") && name != "index.md" }
    end

    def notes(found)
      case found.kind
      when :git
        list = []
        list << "#{Paths.tilde(found.top)} is $HOME, a git repository: every folder under it is in that repository" if home_repo?(found)
        marker = MemoryPaths.nearest_marker(@cwd, home: @home)
        list << "#{Paths.tilde(File.join(marker, MemoryPaths::MARKER))} is ignored: the git repository is the project" if marker
        list
      when :none then ["no git repository or chi project marker here: chi project init makes this folder a project"]
      else []
      end
    end

    def home_repo?(found)
      !@home.to_s.empty? && Guardrails::PathResolve.real(found.top) == Guardrails::PathResolve.real(@home)
    end

    def run_init(dir)
      dir = File.expand_path(dir, @cwd)
      found = lookup(dir)
      if found.git?
        note = home_repo?(found) ? " ($HOME is a git repository: every folder under it is in it)" : ""
        @stdout.puts("#{Paths.tilde(dir)} is in the git repository #{Paths.tilde(found.top)}: the repository already is " \
                     "the project, nothing written#{note}")
        return CLI::Exit::OK
      end
      if MemoryPaths.above_home?(dir, home: @home)
        error_line("#{command_name}: #{Paths.tilde(dir)} is $HOME, a folder above it or /: it can't be a chi project " \
                   "(every folder under it would be one); mark a folder inside it")
        return CLI::Exit::FAILED
      end

      root = found.marker? ? found.root : nil
      if root && root == Guardrails::PathResolve.real(dir)
        @stdout.puts("#{Paths.tilde(root)} is already a chi project")
        return CLI::Exit::OK
      end

      write_marker(dir)
      report_init(File.realpath(dir), nested_in: root)
      CLI::Exit::OK
    rescue SystemCallError => e
      error_line("#{command_name}: couldn't write #{Paths.tilde(File.join(dir, MemoryPaths::MARKER))}: #{e.message}")
      CLI::Exit::FAILED
    end

    def write_marker(dir)
      marker = File.join(dir, MemoryPaths::MARKER)
      FileUtils.mkdir_p(File.dirname(marker))
      File.write(marker, MARKER_TEXT)
    end

    def report_init(root, nested_in:)
      nested = nested_in ? ", its own project nested in #{Paths.tilde(nested_in)}" : ""
      @stdout.puts("#{Paths.tilde(root)} is now a chi project#{nested} (#{Paths.tilde(File.join(root, MemoryPaths::MARKER))})")
      row("memories", memories_line(root))
      sessions_note(root)
    end

    # Sessions in the new project (not one under DIR that a nested
    # repository or marked folder keeps): a running one keeps its old project in its
    # prompt (the memories folder line, the AGENTS.md chain) until it
    # restarts; a running chi web groups the older ones after its restart
    # (SessionHub looked their project up once).
    def sessions_note(root)
      rows = @sessions.call.select { |r| !r.cwd.to_s.empty? && lookup(r.cwd.to_s).root == root }
      return if rows.empty?

      live = rows.select(&:live)
      unless live.empty?
        @stdout.puts("running sessions in it keep the old project in their prompt until restarted " \
                     "(chi sessions restart ID): #{live.map { |r| r.id[0, 8] }.join(", ")}")
      end
      @stdout.puts("#{rows.size} saved session(s) in it join the project in a running chi web after its restart")
    rescue StandardError => e
      error_line("#{command_name}: couldn't list this machine's sessions (#{e.message})")
    end
  end
end
