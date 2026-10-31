# frozen_string_literal: true

require "json"
require "time"
require_relative "context_sources"
require_relative "context_fetch"
require_relative "context_providers"
require_relative "context_report_command"
require_relative "memory_paths"
require_relative "session"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "redacted_inspect"
require_relative "session_access/local"

module Samagotchi
  # `chi context`: attach live external text to sessions (ContextSources).
  # A source is a command chi runs every so often, or text pushed into it;
  # the session's worker leaves a short note when it changes and the model
  # reads the text with context_read.
  class ContextCommand
    include CLI::Command
    include RedactedInspect

    USAGE = <<~TEXT
      Usage: chi context <add|push|ls|show|refresh|rm|mute|unmute|report> [options] [TARGET]
        add NAME (--cmd CMD | --push) [--every SECONDS] [--why TEXT] [--hint TEXT] [--[no-]movable] TARGET
        add URL [--why TEXT] [--hint TEXT] [--[no-]movable] TARGET   a URL an installed bundle's provider knows (github-pr: a PR)
              a source: CMD prints its text (plain, or JSON {"text", "summary", "wake", "hint"});
              --push: text comes from chi context push. --every: how often CMD runs
              (seconds, at least 30; default context.every_seconds). --why: why it's attached;
              --hint: one line, often its URL. NAME: a-z, 0-9 and -, up to 40.
              --movable / --no-movable: whether a continue or a fork takes it to the new
              session (default: a --cmd or URL source moves, a --push one stays).
        push NAME [-m TEXT] [TARGET]        new text for a --push source (stdin without -m; text or JSON)
        ls [TARGET] [--format json]         the sources, their age and state; a session's candidates
        show NAME [--json] [TARGET]         the text (--json: the source and its snapshot)
        refresh NAME [TARGET]               run NAME's command now, here (a live worker absorbs the result)
        rm NAME TARGET                      detach a source
        mute|unmute NAME ID...              a project's source, ignored by one session
        report [--days N]                   the candidate judge's counts (this machine's log)
      TARGET: session ids or unique prefixes, or --project (this git repository's
        sessions, all of them). Inside a chi session (its execute) the default is that
        session. Find ids with: chi sessions list [--live]
    TEXT

    SUBCOMMANDS = %w[add push ls show refresh rm mute unmute report].freeze

    FLAGS = {
      "add" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--cmd"
        f.switch "--push"
        f.value "--every"
        f.value "--why"
        f.value "--hint"
        f.switch "--movable"
        f.switch "--no-movable", key: :movable, set: false
        f.switch "--project"
      end,
      "push" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "-m", "--message", key: :text
        f.switch "--project"
      end,
      "ls" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--format"
        f.switch "--project"
      end,
      "show" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.switch "--json"
        f.switch "--project"
      end,
      "refresh" => CLI::Flags.new(help: HELP_WORDS) { |f| f.switch "--project" },
      "rm" => CLI::Flags.new(help: HELP_WORDS) { |f| f.switch "--project" },
      "mute" => CLI::Flags.new(help: HELP_WORDS),
      "unmute" => CLI::Flags.new(help: HELP_WORDS),
      "report" => ContextReportCommand::FLAGS
    }.freeze

    # Where a command acts: a session (its own sources, then its project's)
    # or a project's sources. +label+ names it in the output, +cwd+ is
    # where its session's sources run (ContextPoller's choice).
    Target = Data.define(:session_id, :project_root, :cwd, :label) do
      def project? = session_id.nil?
    end

    # Why chi context rm NAME ID (and chi web's DELETE …/context/NAME?own=1)
    # leaves a source the session's project has.
    def self.project_source_message(name) = "#{name} is the project's: chi context rm #{name} --project, or mute it for this session"

    # @param argv [Array<String>] the arguments after "context"
    # @param clock [#call] now, for ls's ages ("4s ago")
    # @param access [SessionAccess::Local, nil] where the sessions are;
    #   default this machine's, in +state_dir+
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV, cwd: Dir.pwd,
                   clock: -> { Time.now }, access: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @env = env
      @cwd = cwd
      @clock = clock
      @access = access || SessionAccess::Local.new(state_dir: @state_dir)
    end

    # @return [Integer] exit status: 0 done, 1 refused or failed, 2 usage
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)
      # Its own command (its own flags and usage): this machine's log.
      if @sub == "report"
        return ContextReportCommand.new(@argv[1..], stdout: @stdout, stderr: @stderr, state_dir: @state_dir).run
      end

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      send(:"run_#{@sub}", parsed.options, parsed.args)
    rescue ContextSources::Invalid => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi context #{@sub}" : "chi context"
    def usage_on_error = nil

    def run_add(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name
      return add_url(name, options, args) if name.match?(%r{\Ahttps?://})
      return usage_error("give --cmd CMD or --push") unless options[:cmd] || options[:push]
      return usage_error("--cmd and --push don't go together") if options[:cmd] && options[:push]
      return usage_error("--every is for a --cmd source") if options[:every] && options[:push]
      return usage_error("--cmd is empty") if options[:cmd] && options[:cmd].strip.empty?

      ContextSources.check_name!(name)
      source = ContextSources::Source.new(
        name: name, cmd: options[:cmd], every_seconds: ContextSources.check_every!(options[:every]),
        why: ContextSources.one_line(options[:why], ContextSources::LINE_MAX_CHARS),
        hint: ContextSources.one_line(options[:hint], ContextSources::LINE_MAX_CHARS),
        scope: nil, added_by: added_by, created_at: Time.now.utc.iso8601, movable: options[:movable]
      )
      each_target(options, args) do |target|
        add_to(target, source)
        @stdout.puts("#{target.label}  attached #{name}")
        true
      end
    end

    # Attaches +source+ to +target+; a movable flag an older chi web
    # dropped (its answer has no movable) is a warning: the source is
    # attached with the default.
    def add_to(target, source)
      warn_movable_dropped(target, source.name) if @access.context_add(target, source).movable_dropped
    end

    def warn_movable_dropped(target, name)
      error_line("#{command_name}: warning: the remote's chi web is too old for --movable/--no-movable: " \
                 "#{name} on #{target.label} has the default (update chi there)")
    end

    # A URL through the installed bundles' providers (ContextProviders):
    # the provider gives the name, command, hint and interval. Not gated
    # like --cmd (chi-context-cmd): the command is the bundle's.
    def add_url(url, options, args)
      if options[:cmd] || options[:push] || options[:every]
        return usage_error("a URL's command comes from its provider: give no --cmd, --push or --every")
      end
      return add_remote_url(url, options, args) if @access.remote?

      resolved = ContextProviders.resolve(url)
      return fail_line("no installed bundle resolves #{url} (chi bundle install github-pr for GitHub PRs)") unless resolved

      source = ContextSources::Source.new(
        name: resolved.name, cmd: resolved.cmd, every_seconds: resolved.every_seconds,
        why: ContextSources.one_line(options[:why] || resolved.why, ContextSources::LINE_MAX_CHARS),
        hint: ContextSources.one_line(options[:hint] || resolved.hint, ContextSources::LINE_MAX_CHARS),
        scope: nil, added_by: added_by, created_at: Time.now.utc.iso8601, provider: resolved.bundle,
        movable: options[:movable]
      )
      each_target(options, args) do |target|
        add_to(target, source)
        @stdout.puts("#{target.label}  attached #{source.name}")
        true
      end
    rescue ContextProviders::Invalid => e
      fail_line(e.message)
    end

    # A URL on a remote: its installed bundles' providers resolve it there.
    def add_remote_url(url, options, args)
      why = ContextSources.one_line(options[:why], ContextSources::LINE_MAX_CHARS)
      hint = ContextSources.one_line(options[:hint], ContextSources::LINE_MAX_CHARS)
      each_target(options, args) do |target|
        added = @access.context_add_url(target, url, why: why, hint: hint, added_by: added_by, movable: options[:movable])
        warn_movable_dropped(target, added.name) if added.movable_dropped
        @stdout.puts("#{target.label}  attached #{added.name}")
        true
      end
    rescue ContextProviders::Invalid => e
      fail_line(e.message)
    end

    def run_push(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      text = utf8(options[:text] || read_stdin)
      return usage_error("no text: pass -m TEXT or pipe it in") unless text

      fetched = ContextSources.parse_output(text)
      each_target(options, args) do |target|
        pushed = @access.context_push(target, name, fetched)
        case pushed.status
        when :missing
          no_source(target, name)
          next false
        when :not_push
          # A command source's text is its command's (R2): a push between
          # two fetches would read as a change and then vanish.
          error_line("#{command_name}: #{SessionAccess::ContextPush.not_push_message(name)}")
          next false
        when :continued
          error_line("#{command_name}: #{SessionAccess::ContextPush.continued_message(name, target.session_id, pushed.next_id)}")
          next false
        end

        @stdout.puts("#{target.label}  #{name}: #{pushed.revision == pushed.before ? "unchanged" : "new text"} " \
                     "(#{pushed.revision[0, 12]})")
        true
      end
    end

    def run_ls(options, args)
      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      targets = targets(options, args) or return CLI::Exit::FAILED
      rows = targets.flat_map { |target| @access.context_entries(target).map { |entry| row(target, entry) } }
      candidates = targets.flat_map { |target| @access.context_candidates(target).map { |entry| candidate_row(target, entry) } }
      if format == "json"
        @stdout.puts(JSON.pretty_generate(rows + candidates))
      else
        rows.empty? ? @stdout.puts("no attached context") : print_rows(rows, labels: targets.size > 1)
        print_candidates(candidates, labels: targets.size > 1)
      end
      0
    end

    # A candidate's line of ls (its --format json object, marked candidate).
    # @param entry [SessionAccess::ContextCandidate]
    def candidate_row(target, entry)
      candidate = entry.candidate
      { "target" => target.label, "session_id" => target.session_id, "candidate" => true, "name" => candidate.name,
        "status" => entry.status, "title" => candidate.title, "url" => candidate.url, "cmd" => candidate.cmd,
        "mentions" => candidate.mentions, "proposed_by" => candidate.proposed_by, "at" => candidate.at }.compact
    end

    def print_candidates(rows, labels:)
      return if rows.empty?

      @stdout.puts("candidates (attached when the session's owner mentions one):")
      lines = rows.map { |r| [*(labels ? [r["target"]] : []), r["name"], r["status"], r["title"].to_s] }
      widths = lines.transpose.map { |column| column.map(&:length).max }
      lines.each { |line| @stdout.puts("  #{line.zip(widths).map { |cell, w| cell.ljust(w) }.join("  ").rstrip}") }
    end

    def run_show(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      targets = targets(options, args) or return CLI::Exit::FAILED
      return usage_error("show takes one target") if targets.size > 1

      entry = @access.context_entry(targets.first, name) or return no_source(targets.first, name)
      snapshot = entry.snapshot
      if options[:json]
        @stdout.puts(JSON.pretty_generate({ "source" => entry.source.to_h, "snapshot" => snapshot.to_h }))
        return 0
      end
      unless snapshot.text?
        return fail_line("#{name} has no text yet#{" (last error: #{snapshot.error})" if snapshot.error}")
      end

      @stdout.write(snapshot.text)
      @stdout.write("\n") unless snapshot.text.end_with?("\n")
      0
    end

    # Runs the command in this process, not the worker's: the result shows
    # here, and the worker sees the new snapshot on its next loop. The
    # source's lock keeps the two from running it at once. Local only
    # (SessionAccess::Contract): it runs the command on this machine.
    def run_refresh(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      each_target(options, args) do |target|
        attached = find(target, name) or next false
        if attached.source.push?
          error_line("#{command_name}: #{name} is pushed (chi context push), it has no command to run")
          next false
        end

        cwd = attached.location.session? ? target.cwd : ContextSources.project_cwd(target.project_root, target.cwd)
        outcome = ContextFetch.fetch(attached, cwd: cwd)
        refresh_line(target, name, outcome)
      end
    end

    def refresh_line(target, name, outcome)
      case outcome.status
      when :new, :same
        @stdout.puts("#{target.label}  #{name}: #{outcome.status == :new ? "new text" : "unchanged"} " \
                     "(#{outcome.snapshot.revision[0, 12]})")
        true
      when :busy
        error_line("#{command_name}: #{name} is being fetched right now (by its worker); try again in a moment")
        false
      when :gone
        error_line("#{command_name}: #{name} was removed while it ran; nothing was kept")
        false
      else
        error_line("#{command_name}: #{name} failed: #{outcome.error}")
        false
      end
    end

    def run_rm(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      ContextSources.check_name!(name)
      each_target(options, args) do |target|
        case @access.context_remove(target, name)
        when :removed
          @stdout.puts("#{target.label}  detached #{name}")
          next true
        when :project
          error_line("#{command_name}: #{self.class.project_source_message(name)}")
        else
          error_line("#{command_name}: no source #{name} for #{target.label}")
        end
        false
      end
    end

    # Local only (SessionAccess::Contract): the session's muted/ files here.
    def run_mute(options, args) = mute_or_unmute(options, args, mute: true)
    def run_unmute(options, args) = mute_or_unmute(options, args, mute: false)

    def mute_or_unmute(_options, args, mute:)
      name = args.shift
      return usage_error("give the source's NAME") unless name
      return usage_error("give session ids") if args.empty?

      ContextSources.check_name!(name)
      each_target({}, args) do |target|
        own = location_of(target)
        if mute
          find(target, name) or next false
          own.mute(name)
        else
          own.unmute(name)
        end
        @stdout.puts("#{target.label}  #{mute ? "muted" : "unmuted"} #{name}")
        true
      end
    end

    # @yield [Target] each target; the block returns whether it worked
    # @return [Integer] exit status
    def each_target(options, args, &)
      targets = targets(options, args) or return CLI::Exit::FAILED
      targets.map(&).all? ? 0 : CLI::Exit::FAILED
    end

    # @return [Array<Target>, nil] nil after an error line
    def targets(options, args)
      if options[:project]
        unless args.empty?
          usage_error("--project takes no session ids")
          return nil
        end
        target = project_target or return nil
        return [target]
      end
      if args.empty?
        own = inside_session unless @access.remote?
        unless own
          # Remotely no default: the session chi runs in is this machine's.
          error_line("#{command_name}: give session ids (or unique prefixes)" \
                     "#{", or --project; inside a chi session it's that session" unless @access.remote?}")
          return nil
        end
        args = [own]
      end

      resolved = args.uniq.map { |given| session_target(given) }
      resolved.all? ? resolved.uniq : nil
    end

    # A project's sources: local only (SessionAccess::Contract), this
    # machine's checkout.
    def project_target
      unless MemoryPaths.in_repo?(@cwd)
        error_line("#{command_name}: --project needs a git repository, and #{@cwd} is in none")
        return nil
      end

      root = MemoryPaths.project_root(@cwd)
      # Its sources run in the root, or in this checkout when the root is a
      # git dir (ContextSources.project_cwd).
      Target.new(session_id: nil, project_root: root, cwd: MemoryPaths.work_tree_root(@cwd) || @cwd,
                 label: "project #{File.basename(root)}")
    end

    def session_target(given)
      id = @access.resolve_id(given)
      session = @access.show(id)
      Target.new(session_id: id, project_root: session.project_root, cwd: session.working_directory, label: id[0, 8])
    rescue ArgumentError => e
      message = e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"
      error_line("#{command_name}: #{message}")
      nil
    end

    # Who adds a source: an agent (chi's execute runs this in a session)
    # or the user's cli.
    def added_by = inside_session ? "agent" : "cli"

    # The session chi's execute runs this in (SAMAGOTCHI_PARENT_SESSION;
    # "chi" is a run with no session). Machine-local (a session on this
    # machine): remotely it is no default target (#targets), the ids are
    # given.
    def inside_session
      id = @env.fetch("SAMAGOTCHI_PARENT_SESSION", "").to_s.strip
      id.empty? || id == "chi" ? nil : id
    end

    # The folder a target's own sources live in (refresh, mute: local only).
    def location_of(target) = @access.context_location(target)

    # A source as the target sees it (a session: its own, then its
    # project's), for refresh and mute (local only).
    # @return [ContextSources::Attached, nil] nil after an error line
    def find(target, name)
      found = @access.context_attached(target, name)
      no_source(target, name) unless found
      found
    end

    # @return [Integer] 1, after the line
    def no_source(target, name)
      error_line("#{command_name}: no source #{name} for #{target.label}")
      CLI::Exit::FAILED
    end

    # One line of ls (its --format json object).
    # @param entry [SessionAccess::ContextEntry]
    def row(target, entry)
      source = entry.source
      snapshot = entry.snapshot
      { "target" => target.label, "session_id" => target.session_id, "name" => source.name, "scope" => source.scope,
        "cmd" => source.cmd, "every_seconds" => source.every_seconds, "why" => source.why, "hint" => source.hint,
        "added_by" => source.added_by, "created_at" => source.created_at, "fetched_at" => snapshot.fetched_at,
        "revision" => snapshot.revision, "summary" => snapshot.summary, "error" => snapshot.error,
        "muted" => entry.muted, "shadowed" => entry.shadowed, "unread" => entry.unread,
        "movable" => (source.movable? if source.scope == "session") }.compact
    end

    def print_rows(rows, labels:)
      lines = rows.map do |r|
        kind = r["cmd"] ? "cmd every #{r["every_seconds"] || "default"}#{"s" if r["every_seconds"]}" : "push"
        state = if r["shadowed"] then "shadowed"
                elsif r["muted"] then "muted"
                elsif r["error"] then "error: #{r["error"]}"
                elsif r["revision"].nil? then "no text yet"
                else
                  "ok"
                end
        state = "#{state} · stays" if r["movable"] == false
        [*(labels ? [r["target"]] : []), r["name"], r["scope"], kind, age(r["fetched_at"]), state, r["why"].to_s]
      end
      widths = lines.transpose.map { |column| column.map(&:length).max }
      lines.each { |line| @stdout.puts(line.zip(widths).map { |cell, w| cell.ljust(w) }.join("  ").rstrip) }
    end

    def age(iso)
      return "-" unless iso

      seconds = (@clock.call - Time.iso8601(iso)).to_i
      if seconds < 60 then "#{seconds}s ago"
      elsif seconds < 3600 then "#{seconds / 60}m ago"
      elsif seconds < 86_400 then "#{seconds / 3600}h ago"
      else
        "#{seconds / 86_400}d ago"
      end
    rescue ArgumentError
      "-"
    end

    def fail_line(message)
      error_line("#{command_name}: #{message}")
      CLI::Exit::FAILED
    end
  end
end
