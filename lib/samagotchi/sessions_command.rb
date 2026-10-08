# frozen_string_literal: true

require "json"
require_relative "session"
require_relative "session_manager"
require_relative "session_retention"
require_relative "project_scope"
require_relative "session_metrics"
require_relative "recap_store"
require_relative "session_delete_command"
require_relative "session_archive_command"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi sessions`: list, stop, restart, archive/unarchive, delete, prune and clean
  # sessions from the shell (bin/chi dispatches here before OptionParser;
  # the subcommands have their own flags). Not SessionCommands, the REPL's
  # slash commands for sessions (session_commands.rb).
  class SessionsCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi sessions <list|stop|restart|archive|unarchive|delete|prune|clean> [options]
        list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
             [--live] [--cwd PATH] [--format text|json|tsv] [--archived]
             --live: sessions a worker runs now (the ones chi note reaches), 10 unless --limit
             --cwd PATH: sessions in PATH or below; json/tsv (id<TAB>description) are for scripts
             [--scope=all]: every project's sessions; by default only this git project's (all outside a repo)
             --archived: archived sessions too (marked [archived]; json: archived: true)
        stop ID...   # stop each session's worker (IDs or unique prefixes); chi --resume ID then starts a fresh one
        restart ID...   # hand each session to a new worker on the newest chi installed; refused while a turn, question or reminder would be lost
        archive ID...   # hide sessions (and their delegates) from every list and keep them for good; unarchive ID... brings them back
        delete [--force] ID...   # delete sessions for good (IDs or unique prefixes); --force stops a live worker first
        prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
        clean [--dry-run] [--days N]   # test sessions (SAMAGOTCHI_ENV=test, CI) and leftover chi scratch ones: all of them, or those older than N days
      Defaults: days=14 keep=500 keep_status=none (config: session.retention_days, session.max_count, session.keep_status)
    TEXT

    STOP_USAGE = "Usage: chi sessions stop ID...\n"
    RESTART_USAGE = "Usage: chi sessions restart ID...\n"
    SUBCOMMANDS = %w[list stop restart archive unarchive delete prune clean].freeze

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
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
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
        return Samagotchi::SessionDeleteCommand.new(@argv[1..], stdout: @stdout, stderr: @stderr).run
      when "archive", "unarchive"
        return Samagotchi::SessionArchiveCommand.new(@sub, @argv[1..], stdout: @stdout, stderr: @stderr).run
      end

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      @opts = integers(parsed.options)
      case @sub
      when "list" then list
      when "stop" then stop(parsed.args)
      when "restart" then restart(parsed.args)
      else prune(@sub)
      end
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi sessions #{@sub}" : "chi sessions"
    def usage_text = { "stop" => STOP_USAGE, "restart" => RESTART_USAGE }.fetch(@sub, USAGE)

    # quirk: a number that isn't one is 0 (--days=abc turns the age limit off)
    def integers(options)
      options.to_h { |key, value| [key, INTEGER_OPTIONS.include?(key) ? value.to_i : value] }
    end

    # The flags a list row carries: a chi scratch session, a test run, an
    # archived one, and the turn's stopper (see #stopped_flag).
    def session_flag(scratch:, test_run:, archived:, stopped_by: nil)
      flag = if scratch
               " [scratch]"
             else
               (test_run ? " [test]" : "")
             end
      flag += " [archived]" if archived
      flag + stopped_flag(stopped_by)
    end

    # The marker for a turn a hook stopped: "[looped]" for loop-guard (the
    # bundle's thinking watch, and the word `chi sessions stats` uses for its
    # cuts), "[stopped by X]" for any other hook; "" otherwise. A cut with no
    # retry left records the same stopped_by.
    def stopped_flag(by)
      return "" if by.to_s.empty?

      by.to_s == "loop-guard" ? " [looped]" : " [stopped by #{by}]"
    end

    def list
      format, scope, cwd = @opts.values_at(:format, :scope, :cwd)
      unless format.nil? || %w[text json tsv].include?(format)
        return usage_error("unknown format #{format.inspect}: use --format text|json|tsv")
      end
      return usage_error("unknown scope #{scope.inspect}: use --scope=project|all") unless scope.nil? || %w[project all].include?(scope)

      # The current git project's sessions (Samagotchi::ProjectScope), like
      # chi web's; --scope=all, a folder in no repo or an explicit --cwd: every
      # project's.
      project = scope == "all" || cwd ? nil : Samagotchi::ProjectScope.root_for(Dir.pwd)
      scope_note = ->(count) { "#{count} session(s) in #{File.basename(project)} (--scope=all: every project)" }

      # The picker (chi note from a script): filters apply before the limit,
      # and test runs stay out, unless this is one (SAMAGOTCHI_ENV=test, CI):
      # then its own sessions are what it looks for.
      return list_summaries(project, scope_note) if @opts[:live] || cwd || (format && format != "text")

      list_plain(project, scope_note)
    end

    def list_summaries(project, scope_note)
      live, cwd, limit, include_archived, format, sort, order =
        @opts.values_at(:live, :cwd, :limit, :include_archived, :format, :sort, :order)
      summaries = Samagotchi::SessionManager.session_summaries(
        live: live, cwd: cwd, limit: limit || (live ? 10 : nil), include_tests: Samagotchi::Session.test_session_env?,
        project_root: project,
        include_archived: include_archived, sort: sort, order: order
      )
      case format
      when "json"
        # owner: "worker", "tui" (a chi REPL: it takes no notes or messages)
        # or nil; recap: the saved recap's first sentence, or nil; project:
        # its git project's root, or nil
        # parent_id: the session that delegated it (the delegate tool), or nil
        # delegate: started by the delegate tool (a fork has a parent_id too)
        # archived: hidden from the lists (only with --archived can it be true)
        # scratch: a `chi scratch` session (deleted when its REPL ends, a
        # leftover one at the next sweep)
        # ctx_pct: how full the context was after the last turn, or nil
        # waiting: the kind of question it waits on (question, approval,
        # hook: chi answer or the web answers it), or nil; waiting_id: its
        # id, for chi answer --question; relayed_to: the parent session (short
        # id) whose card it also waits in (the approval relay), or nil
        keys = %i[id short_id desc cwd project updated_at live busy owner recap parent_id delegate archived scratch ctx_pct
                  waiting waiting_id relayed_to stopped_by]
        @stdout.puts JSON.generate(summaries.map { |summary| summary.slice(*keys) })
      when "tsv"
        summaries.each { |summary| @stdout.puts "#{summary[:id]}\t#{summary[:desc]}" }
      else
        summaries.each do |summary|
          state = if summary[:relayed_to] then "waiting (in parent #{summary[:relayed_to]})"
                  elsif summary[:waiting] then "waiting"
                  elsif summary[:busy] then "running"
                  else summary[:live] ? "live" : summary[:status].to_s
                  end
          # The saved recap's first sentence says more than the last prompt
          # (text only: tsv and json keep desc for pickers).
          desc = summary[:desc]
          if summary[:recap]
            desc = [File.basename(summary[:cwd].to_s), summary[:recap]].reject(&:empty?).join(" · ")
            desc = "#{desc[0, 59]}…" if desc.length > 60
          end
          # A delegated session points at its parent.
          child = summary[:parent_short_id] ? "  ↳ #{summary[:parent_short_id]}" : ""
          flag = session_flag(scratch: summary[:scratch], test_run: summary[:test_run], archived: summary[:archived],
                              stopped_by: summary[:stopped_by])
          ctx = Samagotchi::SessionMetrics.context_label(summary[:ctx_pct])
          @stdout.puts "#{summary[:id]}  #{state.ljust(8)}  #{ctx.ljust(8)}  #{summary[:updated_at]}  #{desc}#{flag}#{child}"
        end
        if project
          @stdout.puts "#{"\n" unless summaries.empty?}#{scope_note.call(summaries.size)}"
        else
          @stdout.puts summaries.empty? ? "No sessions." : "\n#{summaries.size} session(s)"
        end
      end
      0
    end

    def list_plain(project, scope_note)
      sort, order, limit, include_archived = @opts.values_at(:sort, :order, :limit, :include_archived)
      sort ||= "updated_at"
      order ||= "desc"
      sessions = Samagotchi::SessionManager.list_sessions(sort: sort, order: order, limit: limit, project_root: project,
                                                          include_archived: include_archived)
      # The saved recap's first sentence, else the last prompt (or the first
      # message, before any turn), cut as before.
      state_dir = Samagotchi::Session.default_state_dir
      list_text = lambda do |s|
        recap = Samagotchi::RecapStore.preview(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
        (recap || Samagotchi::SessionManager.summary_text(s))[0, 60]
      end
      # How full the context was after the last turn: "ctx 12%", counted
      # against the session's llm_context budget when one is set and smaller
      # than the window, as the live meter counts it (one registry for the
      # whole table, built when the first row has a saved context). Blank when
      # unknown.
      budgets = nil
      ctx = lambda do |s|
        Samagotchi::SessionMetrics.context_label(
          Samagotchi::SessionMetrics.saved_context_pct(
            Samagotchi::Session.session_dir(s.id, state_dir: state_dir),
            budget_tokens: -> { Samagotchi::LLMContextStrategy.session_budget(s, registry: budgets ||= Samagotchi::HostRegistry.new) }
          )
        )
      end
      # A delegated session points at its parent: ↳ <parent's short id>.
      row = lambda do |s|
        flag = session_flag(scratch: s.scratch, test_run: s.test_run, archived: s.archived, stopped_by: s.stopped_by)
        child = s.parent_id ? "  ↳ #{s.parent_id[0, 8]}" : ""
        # A question waits for an answer (chi answer, the web, chi --attach).
        live = s.pending_question && Samagotchi::SessionManager.worker_live?(s.id, state_dir: state_dir)
        waiting = s.waiting_question(live: !!live)
        status = if waiting&.dig(:relayed_to) then "waiting (in parent #{waiting[:relayed_to]})"
                 elsif waiting then "waiting"
                 else s.status
                 end
        "#{s.id}  #{status.ljust(8)}  #{ctx.call(s).ljust(8)}  #{s.updated_at}  #{list_text.call(s)}#{flag}#{child}"
      end
      if project
        sessions.each { |s| @stdout.puts row.call(s) }
        @stdout.puts "#{"\n" unless sessions.empty?}#{scope_note.call(sessions.size)}"
      elsif sessions.empty?
        @stdout.puts "No sessions."
      else
        sessions.each { |s| @stdout.puts row.call(s) }
        @stdout.puts "\n#{sessions.size} session(s) (sort=#{sort} order=#{order})"
      end
      0
    end

    def stop(ids)
      return usage_error("give session ids") if ids.empty?

      # Each id in turn, like chi sessions delete: stdout is flushed before an
      # error line, so the output keeps the order of the ids given.
      ok = ids.uniq.map do |given|
        begin
          id = Samagotchi::Session.resolve_id(given)
          released = Samagotchi::SessionManager.stop_session(id, wait: 10)
        rescue Samagotchi::SessionManager::OwnedByTUI
          @stdout.flush
          @stderr.puts "session #{id} is open in a chi REPL; close it there first"
          next false
        rescue ArgumentError => e
          @stdout.flush
          @stderr.puts e.message
          next false
        end
        if released
          @stdout.puts "Stopped session #{id}. chi --resume #{id} starts a fresh worker."
        else
          @stdout.flush
          @stderr.puts "Stopped session #{id}, but its worker is still shutting down; try chi --resume #{id} in a moment."
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
          id = Samagotchi::Session.resolve_id(given)
          result = Samagotchi::SessionManager.restart_session(id)
        rescue Samagotchi::SessionManager::OwnedByTUI
          @stdout.flush
          @stderr.puts "session #{id} is open in a chi REPL; close it there first"
          next false
        rescue Samagotchi::SessionManager::RestartRefused => e
          @stdout.flush
          @stderr.puts %i[not_running unsupported].include?(e.reason) ? e.message : "session #{id}: #{e.message}"
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
