# frozen_string_literal: true

require "json"
require_relative "session"
require_relative "session_manager"
require_relative "project_scope"
require_relative "session_metrics"
require_relative "recap_store"
require_relative "session_delete_command"
require_relative "session_archive_command"

module Samagotchi
  # `chi sessions`: list, stop, archive/unarchive, delete, prune and clean
  # sessions from the shell (bin/chi dispatches here before OptionParser;
  # the subcommands have their own flags). Not SessionCommands, the REPL's
  # slash commands for sessions (session_commands.rb).
  class SessionsCommand
    USAGE = <<~TEXT
      Usage: chi sessions <list|stop|archive|unarchive|delete|prune|clean> [options]
        list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
             [--live] [--cwd PATH] [--format text|json|tsv] [--archived]
             --live: sessions a worker runs now (the ones chi note reaches), 10 unless --limit
             --cwd PATH: sessions in PATH or below; json/tsv (id<TAB>description) are for scripts
             [--scope=all]: every project's sessions; by default only this git project's (all outside a repo)
             --archived: archived sessions too (marked [archived]; json: archived: true)
        stop ID...   # stop each session's worker (IDs or unique prefixes); chi --resume ID then starts a fresh one
        archive ID...   # hide sessions (and their delegates) from every list and keep them for good; unarchive ID... brings them back
        delete [--force] ID...   # delete sessions for good (IDs or unique prefixes); --force stops a live worker first
        prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
        clean [--dry-run] [--days N]   # test sessions (SAMAGOTCHI_ENV=test, CI) and leftover chi scratch ones: all of them, or those older than N days
      Defaults: days=14 keep=500 keep_status=none (config: session.retention_days, session.max_count, session.keep_status)
    TEXT

    # @param argv [Array<String>] the arguments after "sessions"
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    # @return [Integer] exit status
    def run
      sessions_args = @argv
      sub = sessions_args[0]
      if sub.nil? || %w[-h --help help].include?(sub)
        @stdout.puts USAGE
        return 0
      end
      dry_run = sessions_args.include?("--dry-run")
      test_only = sessions_args.include?("--test-only") || sessions_args.include?("--test")
      days = nil
      keep = nil
      keep_status = nil
      sort = nil
      order = nil
      limit = nil
      live = sessions_args.include?("--live")
      include_archived = sessions_args.include?("--archived")
      cwd = nil
      format = nil
      scope = nil
      sessions_args.each_with_index do |arg, i|
        nxt = sessions_args[i+1]
        if arg == "--days" && nxt then days = nxt.to_i
        elsif arg.start_with?("--days=") then days = arg.split("=",2).last.to_i
        elsif arg == "--keep" && nxt then keep = nxt.to_i
        elsif arg.start_with?("--keep=") then keep = arg.split("=",2).last.to_i
        elsif arg == "--keep-status" && nxt then keep_status = nxt
        elsif arg.start_with?("--keep-status=") then keep_status = arg.split("=",2).last
        elsif arg == "--sort" && nxt then sort = nxt
        elsif arg.start_with?("--sort=") then sort = arg.split("=",2).last
        elsif arg == "--order" && nxt then order = nxt
        elsif arg.start_with?("--order=") then order = arg.split("=",2).last
        elsif arg == "--limit" && nxt then limit = nxt.to_i
        elsif arg.start_with?("--limit=") then limit = arg.split("=",2).last.to_i
        elsif arg == "--cwd" && nxt then cwd = nxt
        elsif arg.start_with?("--cwd=") then cwd = arg.split("=",2).last
        elsif arg == "--format" && nxt then format = nxt
        elsif arg.start_with?("--format=") then format = arg.split("=",2).last
        elsif arg == "--scope" && nxt then scope = nxt
        elsif arg.start_with?("--scope=") then scope = arg.split("=",2).last
        end
      end
      case sub
      when "delete"
        return Samagotchi::SessionDeleteCommand.new(sessions_args[1..], stdout: @stdout, stderr: @stderr).run
      when "archive", "unarchive"
        return Samagotchi::SessionArchiveCommand.new(sub, sessions_args[1..], stdout: @stdout, stderr: @stderr).run
      when "list"
        unless format.nil? || %w[text json tsv].include?(format)
          @stderr.puts "Unknown format #{format.inspect}: use --format text|json|tsv"
          return 1
        end
        unless scope.nil? || %w[project all].include?(scope)
          @stderr.puts "Unknown scope #{scope.inspect}: use --scope=project|all"
          return 1
        end
        # The current git project's sessions (Samagotchi::ProjectScope), like
        # chi web's; --scope=all, a folder in no repo or an explicit --cwd: every
        # project's.
        project = scope == "all" || cwd ? nil : Samagotchi::ProjectScope.root_for(Dir.pwd)
        scope_note = ->(count) { "#{count} session(s) in #{File.basename(project)} (--scope=all: every project)" }
        # The picker (chi note from a script): filters apply before the limit,
        # and test runs stay out, unless this is one (SAMAGOTCHI_ENV=test, CI):
        # then its own sessions are what it looks for.
        if live || cwd || (format && format != "text")
          summaries = Samagotchi::SessionManager.session_summaries(
            live: live, cwd: cwd, limit: limit || (live ? 10 : nil), include_tests: Samagotchi::Session.test_session_env?,
            project_root: project,
            include_archived: include_archived
          )
          case format
          when "json"
            # owner: "worker", "tui" (a chi REPL: it takes no notes or messages)
            # or nil; recap: the saved recap's first sentence, or nil; project:
            # its git project's root, or nil
            # parent_id: the session that delegated it (the delegate tool), or nil
            # archived: hidden from the lists (only with --archived can it be true)
            # scratch: a `chi scratch` session (deleted when its REPL ends, a
            # leftover one at the next sweep)
            # ctx_pct: how full the context was after the last turn, or nil
            keys = %i[id short_id desc cwd project updated_at live busy owner recap parent_id archived scratch ctx_pct]
            @stdout.puts JSON.generate(summaries.map { |summary| summary.slice(*keys) })
          when "tsv"
            summaries.each { |summary| @stdout.puts "#{summary[:id]}\t#{summary[:desc]}" }
          else
            summaries.each do |summary|
              state = summary[:busy] ? "running" : (summary[:live] ? "live" : summary[:status].to_s)
              # The saved recap's first sentence says more than the last prompt
              # (text only: tsv and json keep desc for pickers).
              desc = summary[:desc]
              if summary[:recap]
                desc = [File.basename(summary[:cwd].to_s), summary[:recap]].reject(&:empty?).join(" · ")
                desc = "#{desc[0, 59]}…" if desc.length > 60
              end
              # A delegated session points at its parent.
              child = summary[:parent_short_id] ? "  ↳ #{summary[:parent_short_id]}" : ""
              flag = summary[:scratch] ? " [scratch]" : (summary[:test_run] ? " [test]" : "")
              flag += " [archived]" if summary[:archived]
              ctx = Samagotchi::SessionMetrics.context_label(summary[:ctx_pct])
              @stdout.puts "#{summary[:id]}  #{state.ljust(8)}  #{ctx.ljust(8)}  #{summary[:updated_at]}  #{desc}#{flag}#{child}"
            end
            if project
              @stdout.puts "#{summaries.empty? ? "" : "\n"}#{scope_note.call(summaries.size)}"
            else
              @stdout.puts summaries.empty? ? "No sessions." : "\n#{summaries.size} session(s)"
            end
          end
          return 0
        end
        sort ||= "updated_at"
        order ||= "desc"
        sessions = Samagotchi::SessionManager.list_sessions(sort: sort, order: order, limit: limit, project_root: project,
                                                            include_archived: include_archived)
        # The saved recap's first sentence, else the last prompt, cut as before.
        state_dir = Samagotchi::Session.default_state_dir
        list_text = lambda do |s|
          recap = Samagotchi::RecapStore.preview(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
          (recap || Samagotchi::SessionManager.one_line(s.last_prompt))[0, 60]
        end
        # A delegated session points at its parent: ↳ <parent's short id>.
        row = lambda do |s|
          flag = s.scratch ? " [scratch]" : (s.test_run ? " [test]" : "")
          flag += " [archived]" if s.archived
          child = s.parent_id ? "  ↳ #{s.parent_id[0, 8]}" : ""
          # How full the context was after the last turn: "ctx 12%", blank when unknown.
          ctx = Samagotchi::SessionMetrics.context_label(
            Samagotchi::SessionMetrics.saved_context_pct(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
          )
          "#{s.id}  #{s.status.ljust(8)}  #{ctx.ljust(8)}  #{s.updated_at}  #{list_text.call(s)}#{flag}#{child}"
        end
        if project
          sessions.each { |s| @stdout.puts row.call(s) }
          @stdout.puts "#{sessions.empty? ? "" : "\n"}#{scope_note.call(sessions.size)}"
        elsif sessions.empty?
          @stdout.puts "No sessions."
        else
          sessions.each { |s| @stdout.puts row.call(s) }
          @stdout.puts "\n#{sessions.size} session(s) (sort=#{sort} order=#{order})"
        end
        return 0
      when "stop"
        ids = sessions_args[1..]
        if ids.empty? || ids.any? { |arg| arg.start_with?("-") }
          @stderr.puts "Usage: chi sessions stop ID..."
          return 1
        end
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
        return(ok.all? ? 0 : 1)
      when "prune", "clean"
        test_only = true if sub == "clean" && !sessions_args.include?("--all")
        # Test sessions are throwaway: clean takes them whatever their age,
        # unless --days asks for the older ones only. Live workers and
        # keep_status still protect a session.
        any_age = sub == "clean" && test_only && days.nil?
        result = Samagotchi::SessionManager.prune_sessions(days: days, max_count: keep, keep_status: keep_status, dry_run: dry_run,
                                                           test_only: test_only, any_age: any_age)
        mode = dry_run ? "Would delete" : "Deleted"
        @stdout.puts "#{mode} #{result[:deleted].size} sessions (kept #{result[:kept].size}, skipped #{result[:skipped].size})"
        if result[:deleted].any?
          result[:deleted].each { |id| @stdout.puts "  #{id}" }
        end
        if dry_run && result[:deleted].any?
          @stdout.puts "\nRun without --dry-run to delete."
        end
        return 0
      else
        @stderr.puts "Unknown sessions subcommand: #{sub}. Use: list, stop, archive, unarchive, delete, prune, clean"
        return 1
      end
    end
  end
end
