# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "guardrails/path_resolve"
require_relative "memory_paths"
require_relative "paths"
require_relative "project_init"

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
      Usage: chi project [init [--new-id] [DIR]]
        (none)       this folder's project: how it was found (git, marker or none), its root, its
                     top, its id and its project memories folder
        init [DIR]   make DIR (default: this folder; created when missing) a chi project: writes
                     DIR/#{MemoryPaths::MARKER} with an id, so DIR and every subfolder share one project
                     memories folder (kept when DIR moves) and group their sessions. Not in a git
                     repository (it already is the project), nor $HOME or a folder above it. On a
                     marked folder with no id: adopts one, moving its folders to it
        --new-id     a marked folder's own new id (a copied folder going its own way): its
                     memories and project context copied to it
    TEXT

    SUBCOMMANDS = %w[init].freeze
    FLAGS = {
      nil => CLI::Flags.new(help: HELP_WORDS, args: false),
      "init" => CLI::Flags.new(help: HELP_WORDS) { |f| f.switch "--new-id" }
    }.freeze

    # @param cwd [String] the folder asked about (Dir.pwd)
    # @param home [String, nil] $HOME (markers at or above it are ignored)
    # @param sessions [#call, nil] () → this machine's SessionRows (for
    #   init's restart note and its adoption's running check;
    #   SessionManager.session_rows by default)
    # @param state_dir [String, nil] the sessions dir (an adoption moves the
    #   project context folders beside it)
    def initialize(argv, stdout: $stdout, stderr: $stderr, cwd: Dir.pwd, env: ENV, home: MemoryPaths.default_home,
                   sessions: nil, state_dir: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @cwd = cwd
      @env = env
      @home = home
      @state_dir = state_dir
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

      dir = File.expand_path(parsed.args.first || @cwd, @cwd)
      parsed.options[:new_id] ? run_new_id(dir) : run_init(dir)
    end

    private

    def command_name = @sub ? "chi project #{@sub}" : "chi project"
    def usage_on_error = nil

    def lookup(dir) = MemoryPaths.lookup(dir, home: @home)

    def run_show
      found = lookup(@cwd)
      row("kind", found.kind.to_s)
      if found.project?
        row("root", found.root)
        row("top", found.top)
      end
      row("id", found.id) if found.id
      row("memories", memories_line(found))
      notes(found).each { |note| row("note", note) }
      CLI::Exit::OK
    end

    def row(label, value) = @stdout.puts("#{label.ljust(9)}#{value}")

    # @param found [MemoryPaths::ProjectLookup] the project (its root and id key the folder)
    def memories_line(found)
      dir = File.join(MemoryPaths.projects_dir(env: @env), MemoryPaths.key_for(root: found.root, id: found.id))
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
      outcome = ProjectInit.adopt(dir, home: @home, env: @env, state_dir: @state_dir, sessions: adopt_rows(dir))
      case outcome.kind
      when :git
        found = MemoryPaths::ProjectLookup.new(kind: :git, root: outcome.root, top: outcome.top)
        note = home_repo?(found) ? " ($HOME is a git repository: every folder under it is in it)" : ""
        @stdout.puts("#{outcome.message}#{note}")
        CLI::Exit::OK
      when :refused
        error_line("#{command_name}: #{outcome.message}")
        CLI::Exit::FAILED
      when :already_marked
        @stdout.puts(outcome.message)
        CLI::Exit::OK
      when :created
        report_init(outcome)
        CLI::Exit::OK
      when :adopted
        @stdout.puts(outcome.message)
        CLI::Exit::OK
      end
    rescue SystemCallError => e
      error_line("#{command_name}: couldn't write #{Paths.tilde(File.join(dir, MemoryPaths::MARKER))}: #{e.message}")
      CLI::Exit::FAILED
    end

    def run_new_id(dir)
      outcome = ProjectInit.new_id(dir, home: @home, env: @env, state_dir: @state_dir)
      if outcome.kind == :refused
        error_line("#{command_name} --new-id: #{outcome.message}")
        return CLI::Exit::FAILED
      end

      @stdout.puts(outcome.message)
      sessions_note(outcome.root, restart: "keep the id they started with until restarted")
      CLI::Exit::OK
    end

    # The rows an adoption checks for running sessions: only for a marked
    # folder (a listing is a walk of every session file).
    def adopt_rows(dir)
      found = lookup(dir)
      return [] if found.git? || found.id

      @sessions.call
    end

    def report_init(outcome)
      root = outcome.root
      nested = outcome.nested_in ? ", its own project nested in #{Paths.tilde(outcome.nested_in)}" : ""
      @stdout.puts("#{Paths.tilde(root)} is now a chi project#{nested} (#{Paths.tilde(File.join(root, MemoryPaths::MARKER))})")
      row("id", outcome.id) if outcome.id
      row("memories", memories_line(lookup(root)))
      @stdout.puts(outcome.message) if outcome.message
      sessions_note(root)
    end

    # Sessions in the new project (not one under DIR that a nested
    # repository or marked folder keeps): a running one keeps its old project in its
    # prompt (the memories folder line, the AGENTS.md chain) until it
    # restarts; a running chi web groups the older ones after its restart
    # (SessionHub looked their project up once).
    def sessions_note(root, restart: nil)
      rows = @sessions.call.select { |r| !r.cwd.to_s.empty? && lookup(r.cwd.to_s).root == root }
      return if rows.empty?

      live = rows.select(&:live)
      unless live.empty?
        @stdout.puts("running sessions in it #{restart || "keep the old project in their prompt until restarted"} " \
                     "(chi sessions restart ID): #{live.map { |r| r.id[0, 8] }.join(", ")}")
      end
      return if restart

      @stdout.puts("#{rows.size} saved session(s) in it join the project in a running chi web after its restart")
    rescue StandardError => e
      error_line("#{command_name}: couldn't list this machine's sessions (#{e.message})")
    end
  end
end
