# frozen_string_literal: true

require "json"
require_relative "session"
require_relative "session_row"
require_relative "session_manager"
require_relative "session_retention"
require_relative "project_scope"
require_relative "analytics_file"
require_relative "session_metrics"
require_relative "session_delete_command"
require_relative "session_archive_command"
require_relative "worker_link"
require_relative "terminal_ui/formatting"
require_relative "terminal_ui/event_renderer"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "session_access/local"

module Samagotchi
  # `chi sessions`: list, stop, restart, archive/unarchive, delete, prune,
  # clean and stats sessions from the shell (bin/chi dispatches here before
  # OptionParser; the subcommands have their own flags). Not SessionCommands,
  # the slash commands a session's worker runs (session_commands.rb).
  class SessionsCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi sessions <list|stop|restart|archive|unarchive|delete|prune|clean|stats> [options]
        list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
             [--live] [--cwd PATH] [--format text|json|tsv] [--archived]
             --live: sessions a worker runs now (the ones chi note reaches), 10 unless --limit
             --cwd PATH: sessions in PATH or below; json/tsv (id<TAB>description) are for scripts
             [--scope=all]: every project's sessions; by default only this git project's (all outside a repo)
             --archived: archived sessions too (marked [archived]; json: archived: true)
        stop ID...   # stop each session's worker (IDs or unique prefixes); chi --resume ID then starts a fresh one
        restart ID...   # hand each session to a new worker on the newest chi installed; keeps its reminders; refused while a turn or question would be lost
        archive ID...   # hide sessions (and their delegates) from every list and keep them for good; unarchive ID... brings them back
        delete [--force] ID...   # delete sessions for good (IDs or unique prefixes); --force stops a live worker first
        prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
        clean [--dry-run] [--days N] [--all]   # test sessions (SAMAGOTCHI_ENV=test, CI) and leftover chi scratch ones: all of them, or those older than N days
             --all: every session, not only test and scratch ones (by the age and count limits, as prune)
        stats ID [--format text|json]   # a session's cost, tokens, progress and own settings, without running a model turn:
             a live worker's GET stats, else the snapshot its saved analytics.json rebuilds (never starts a worker)
      Defaults: days=14 keep=500 keep_status=none (config: session.retention_days, session.max_count, session.keep_status)
    TEXT

    STOP_USAGE = "Usage: chi sessions stop ID...\n"
    RESTART_USAGE = "Usage: chi sessions restart ID...\n"
    STATS_USAGE = "Usage: chi sessions stats ID [--format text|json]\n"
    # How long `stats` waits for a live worker's GET stats before reading the
    # saved analytics.json instead (a stuck worker must not hold a driver).
    STATS_TIMEOUT = 3
    SUBCOMMANDS = %w[list stop restart archive unarchive delete prune clean stats].freeze

    # Each subcommand's flags ("--flag V" or "--flag=V" for a value): an
    # unknown flag, a value flag with nothing after it or an argument where
    # none is taken is a usage error (exit 2). The numbers become integers
    # (#integers).
    FLAGS = {
      "list" => CLI::Flags.new(args: false) do |f|
        %w[--sort --order --limit --cwd --format --scope].each { |name| f.value name }
        f.switch "--live"
        f.switch "--archived", key: :include_archived
      end,
      "stop" => CLI::Flags.new,
      "restart" => CLI::Flags.new,
      "stats" => CLI::Flags.new do |f|
        f.value "--format"
      end,
      "prune" => CLI::Flags.new(args: false) do |f|
        %w[--days --keep --keep-status].each { |name| f.value name }
        f.switch "--dry-run"
        f.switch "--test-only", "--test", key: :test_only
      end,
      "clean" => CLI::Flags.new(args: false) do |f|
        f.value "--days"
        f.switch "--dry-run"
        f.switch "--all"
      end
    }.freeze
    INTEGER_OPTIONS = %i[days keep limit].freeze

    # @param argv [Array<String>] the arguments after "sessions"
    # @param access [SessionAccess::Local, nil] where the sessions are;
    #   default this machine's (delete, archive and unarchive build their
    #   own unless one is given)
    def initialize(argv, stdout: $stdout, stderr: $stderr, access: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @given_access = access
      @access = access || Samagotchi::SessionAccess::Local.new
    end

    # @return [Integer] exit status
    # @return [Integer] exit status: 2 on a usage error
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts USAGE
        return 0
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      case @sub
      when "delete"
        return Samagotchi::SessionDeleteCommand.new(@argv[1..], stdout: @stdout, stderr: @stderr, access: @given_access).run
      when "archive", "unarchive"
        return Samagotchi::SessionArchiveCommand.new(@sub, @argv[1..], stdout: @stdout, stderr: @stderr,
                                                                       access: @given_access).run
      end

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      @opts = integers(parsed.options)
      return usage_error(@opts) if @opts.is_a?(String)

      case @sub
      when "list" then list
      when "stop" then stop(parsed.args)
      when "restart" then restart(parsed.args)
      when "stats" then stats(parsed.args)
      else prune(@sub)
      end
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi sessions #{@sub}" : "chi sessions"
    def usage_text = { "stop" => STOP_USAGE, "restart" => RESTART_USAGE, "stats" => STATS_USAGE }.fetch(@sub, USAGE)

    # The options with --days, --keep and --limit as integers, or the usage
    # error's message for one that isn't a whole number (--days=abc must not
    # turn the age limit off).
    # @return [Hash, String]
    def integers(options)
      bad = options.find { |key, value| INTEGER_OPTIONS.include?(key) && !value.to_s.match?(/\A-?\d+\z/) }
      return "--#{bad[0]} takes a whole number, got #{bad[1].to_s.inspect}" if bad

      options.to_h { |key, value| [key, INTEGER_OPTIONS.include?(key) ? Integer(value, 10) : value] }
    end

    def list
      format, scope, cwd = @opts.values_at(:format, :scope, :cwd)
      refused = format_refusal(format, %w[text json tsv])
      return refused if refused
      return usage_error("unknown scope #{scope.inspect}: use --scope=project|all") unless scope.nil? || %w[project all].include?(scope)

      sort, order = @opts.values_at(:sort, :order)
      unless sort.nil? || Samagotchi::Session::SORT_KEYS.include?(sort)
        return usage_error("unknown sort #{sort.inspect}: use --sort #{Samagotchi::Session::SORT_KEYS.join("|")}")
      end
      unless order.nil? || Samagotchi::Session::SORT_ORDERS.include?(order)
        return usage_error("unknown order #{order.inspect}: use --order #{Samagotchi::Session::SORT_ORDERS.join("|")}")
      end

      # The current git project's sessions (Samagotchi::ProjectScope), like
      # chi web's; --scope=all, a folder in no repo or an explicit --cwd: every
      # project's. Machine-local (this cwd's project): remotely every
      # project's (D4), and --scope=project is --cwd's project there (the
      # server finds its root). The rows are SessionRows, the server's
      # remotely: one line wherever the list runs (SessionRow#cli_line).
      # The picker (chi note from a script): filters apply before the limit,
      # and test runs stay out, unless this is one (SAMAGOTCHI_ENV=test, CI):
      # then its own sessions are what it looks for. The plain listing shows
      # them, marked [test], here and remotely.
      picker = @opts[:live] || cwd || (format && format != "text")
      include_tests = !picker || Samagotchi::Session.test_session_env?
      if @access.remote?
        return usage_error("--scope=project on a remote needs --cwd: a folder there") if scope == "project" && !cwd

        project = scope == "project" ? cwd : nil
        scope_note = ->(count) { "#{count} session(s) in #{File.basename(project)} on #{@access.name} (--scope=all: every project)" }
        return list_summaries(project, scope_note, include_tests: include_tests)
      end
      project = scope == "all" || cwd ? nil : Samagotchi::ProjectScope.root_for(Dir.pwd)
      scope_note = ->(count) { "#{count} session(s) in #{File.basename(project)} (--scope=all: every project)" }
      list_summaries(project, scope_note, include_tests: include_tests)
    end

    def list_summaries(project, scope_note, include_tests:)
      live, cwd, limit, include_archived, format, sort, order =
        @opts.values_at(:live, :cwd, :limit, :include_archived, :format, :sort, :order)
      summaries = @access.summaries(
        live: live, cwd: cwd, limit: limit || (live ? 10 : nil), include_tests: include_tests,
        project_root: project,
        include_archived: include_archived, sort: sort, order: order
      )
      case format
      when "json"
        # SessionRow::JSON_KEYS (its comment says what each one is).
        @stdout.puts JSON.generate(summaries.map { |row| row.to_summary_h.slice(*Samagotchi::SessionRow::JSON_KEYS) })
      when "tsv"
        summaries.each { |row| @stdout.puts "#{row.id}\t#{row.desc}" }
      else
        summaries.each { |row| @stdout.puts row.cli_line }
        if project
          @stdout.puts "#{"\n" unless summaries.empty?}#{scope_note.call(summaries.size)}"
        elsif summaries.empty?
          @stdout.puts "No sessions."
        else
          @stdout.puts "\n#{summaries.size} session(s) (sort=#{sort || "updated_at"} order=#{order || "desc"})"
        end
      end
      0
    end

    # One session's cost, tokens and progress, for a script or an agent that
    # drives sessions (chi send --wait): a live worker's GET stats, else the
    # snapshot its saved analytics.json rebuilds. Never starts a worker, and
    # never sends the model anything. Local only (SessionAccess::Contract):
    # the Bridge's stats and analytics.json on this machine.
    def stats(ids)
      return usage_error("give a session id") if ids.empty?
      return usage_error("stats takes one session id") if ids.size > 1

      format = @opts[:format]
      refused = format_refusal(format)
      return refused if refused

      id = begin
        Samagotchi::Session.resolve_id(ids.first)
      rescue Samagotchi::Session::AmbiguousId => e
        @stdout.flush
        @stderr.puts e.message
        return 1
      end
      session = begin
        Samagotchi::Session.load(id)
      rescue ArgumentError => e
        @stdout.flush
        @stderr.puts e.message
        return 1
      end

      metrics, live, note = stats_snapshot_for(session)
      # The session's own settings (chi --set), as --set names them.
      settings = session.settings.flat
      if format == "json"
        @stdout.puts JSON.generate({ session_id: session.id, status: session.status, live: live, metrics: metrics,
                                     settings: settings })
      else
        @stdout.puts "#{session.id[0, 8]}  #{session.status.ljust(7)} #{session.model_name}"
        metrics = metrics.merge(settings: settings) if metrics && !settings.empty?
        @stdout.puts TerminalUI::Formatting.format_session_metrics(metrics)
        @stdout.puts note if note
      end
      0
    end

    # [snapshot, live, note]: a live worker answers GET stats (no model call);
    # without one — or one that does not answer in time — the snapshot comes
    # from the session's saved analytics.json, rebuilt by SessionMetrics (the
    # same collector a worker runs, loaded from disk). The note says when the
    # worker did not answer. nil when the session has no analytics.json yet.
    # Never starts a worker.
    # @return [Array(Hash, nil, Boolean, String, nil)]
    def stats_snapshot_for(session)
      dir = Samagotchi::Session.session_dir(session.id)
      if (client = Samagotchi::WorkerLink.client(session.id, session_dir: dir, read_timeout: STATS_TIMEOUT))
        body = client.get_json("stats")&.dig("metrics")
        if body.is_a?(Hash)
          return [TerminalUI::EventRenderer.deep_symbolize_keys(body), true, nil]
        end
      end
      return [nil, false, nil] unless File.file?(Samagotchi::AnalyticsFile.path(dir))

      snapshot = Samagotchi::SessionMetrics.new.tap { |m| m.session_id = session.id }.saved_snapshot
      note = live_worker?(session.id) ? "(no live worker answered; from the saved #{Samagotchi::AnalyticsFile::NAME})" : nil
      [snapshot, false, note]
    end

    def live_worker?(session_id) = worker_owned?(session_id, nil)

    def worker_owned?(session_id, state_dir)
      dir = Samagotchi::Session.session_dir(session_id, state_dir: state_dir || Samagotchi::Session.default_state_dir)
      Samagotchi::WorkerLink.resolve(dir, unlink: false).worker_owned?
    end

    def stop(ids)
      return usage_error("give session ids") if ids.empty?

      # Each id in turn, like chi sessions delete: stdout is flushed before an
      # error line, so the output keeps the order of the ids given.
      ok = ids.uniq.map do |given|
        begin
          id = @access.resolve_id(given)
          released = @access.stop(id, wait: Samagotchi::SessionManager::STOP_WAIT)
        rescue Samagotchi::SessionManager::OwnedByTUI => e
          @stdout.flush
          @stderr.puts e.message
          next false
        rescue ArgumentError => e
          @stdout.flush
          @stderr.puts e.message
          next false
        end
        # chi --resume ID, or chi --remote NAME --resume ID.
        resume = @access.invocation.resume(id)
        if released
          @stdout.puts "Stopped session #{id}. #{resume} starts a fresh worker."
        else
          @stdout.flush
          @stderr.puts "Stopped session #{id}, but its worker is still shutting down; try #{resume} in a moment."
        end
        true
      end
      ok.all? ? 0 : 1
    end

    # Each session in turn: its worker hands over to a new one on the newest
    # chi (SessionManager.restart_session), or says why not.
    def restart(ids)
      return usage_error("give session ids") if ids.empty?

      ok = ids.uniq.map do |given|
        begin
          id = @access.resolve_id(given)
          result = @access.restart(id)
        rescue Samagotchi::SessionManager::OwnedByTUI => e
          @stdout.flush
          @stderr.puts e.message
          next false
        rescue Samagotchi::SessionManager::RestartRefused => e
          @stdout.flush
          @stderr.puts %i[not_running unsupported fallback_held stopped failed].include?(e.reason) ? e.message : "session #{id}: #{e.message}"
          next false
        rescue ArgumentError => e
          @stdout.flush
          @stderr.puts e.message
          next false
        end
        @stdout.puts restarted_line(result)
        true
      end
      ok.all? ? 0 : 1
    end

    def restarted_line(result)
      return "Restarting session #{result.session_id}; its new worker is still starting." unless result.version

      from = result.from_version && result.from_version != result.version ? " (was #{result.from_version})" : ""
      "Restarted session #{result.session_id} on chi #{result.version}#{from}."
    end

    # Local only (SessionAccess::Contract): this machine's retention sweep.
    def prune(sub)
      days, keep, keep_status, dry_run, test_only = @opts.values_at(:days, :keep, :keep_status, :dry_run, :test_only)
      test_only = true if sub == "clean" && !@opts[:all]
      # Test sessions are throwaway: clean takes them whatever their age,
      # unless --days asks for the older ones only. Live workers and
      # keep_status still protect a session.
      any_age = sub == "clean" && test_only && days.nil?
      result = Samagotchi::SessionRetention.prune(days: days, max_count: keep, keep_status: keep_status, dry_run: dry_run,
                                                  test_only: test_only, any_age: any_age)
      mode = dry_run ? "Would delete" : "Deleted"
      @stdout.puts "#{mode} #{result[:deleted].size} sessions (kept #{result[:kept].size}, skipped #{result[:skipped].size})"
      if result[:deleted].any?
        result[:deleted].each { |id| @stdout.puts "  #{id}" }
      end
      if dry_run && result[:deleted].any?
        @stdout.puts "\nRun without --dry-run to delete."
      end
      0
    end
  end
end
