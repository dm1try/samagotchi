# frozen_string_literal: true

require "json"
require "time"
require_relative "context_sources"
require_relative "context_fetch"
require_relative "memory_paths"
require_relative "session"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"

module Samagotchi
  # `chi context`: attach live external text to sessions (ContextSources).
  # A source is a command chi runs every so often, or text pushed into it;
  # the session's worker leaves a short note when it changes and the model
  # reads the text with context_read.
  class ContextCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi context <add|push|ls|show|refresh|rm|mute|unmute> [options] [TARGET]
        add NAME (--cmd CMD | --push) [--every SECONDS] [--why TEXT] [--hint TEXT] TARGET
              a source: CMD prints its text (plain, or JSON {"text", "summary", "wake", "hint"});
              --push: text comes from chi context push. --every: how often CMD runs
              (seconds, at least 30; default context.every_seconds). --why: why it's attached;
              --hint: one line, often its URL. NAME: a-z, 0-9 and -, up to 40.
        push NAME [-m TEXT] [TARGET]        new text for NAME (stdin without -m; text or JSON)
        ls [TARGET] [--format json]         the sources, their age and state
        show NAME [--json] [TARGET]         the text (--json: the source and its snapshot)
        refresh NAME [TARGET]               run NAME's command now, here (a live worker absorbs the result)
        rm NAME TARGET                      detach a source
        mute|unmute NAME ID...              a project's source, ignored by one session
      TARGET: session ids or unique prefixes, or --project (this git repository's
        sessions, all of them). Inside a chi session (its execute) the default is that
        session. Find ids with: chi sessions list [--live]
    TEXT

    SUBCOMMANDS = %w[add push ls show refresh rm mute unmute].freeze

    FLAGS = {
      "add" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--cmd"
        f.switch "--push"
        f.value "--every"
        f.value "--why"
        f.value "--hint"
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
      "unmute" => CLI::Flags.new(help: HELP_WORDS)
    }.freeze

    # Where a command acts: a session (its own sources, then its project's)
    # or a project's sources. +label+ names it in the output, +cwd+ is
    # where its session's sources run (ContextPoller's choice).
    Target = Data.define(:session_id, :project_root, :cwd, :label) do
      def project? = session_id.nil?
    end

    # @param argv [Array<String>] the arguments after "context"
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV, cwd: Dir.pwd)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @env = env
      @cwd = cwd
    end

    # @return [Integer] exit status: 0 done, 1 refused or failed, 2 usage
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

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
      if name.match?(%r{\Ahttps?://})
        # C6 resolves a URL through the bundles' providers.
        return fail_line("no provider resolves URLs yet: give a NAME and --cmd CMD or --push")
      end
      return usage_error("give --cmd CMD or --push") unless options[:cmd] || options[:push]
      return usage_error("--cmd and --push don't go together") if options[:cmd] && options[:push]
      return usage_error("--every is for a --cmd source") if options[:every] && options[:push]
      return usage_error("--cmd is empty") if options[:cmd] && options[:cmd].strip.empty?

      ContextSources.check_name!(name)
      source = ContextSources::Source.new(
        name: name, cmd: options[:cmd], every_seconds: ContextSources.check_every!(options[:every]),
        why: ContextSources.one_line(options[:why], ContextSources::LINE_MAX_CHARS),
        hint: ContextSources.one_line(options[:hint], ContextSources::LINE_MAX_CHARS),
        scope: nil, added_by: inside_session ? "agent" : "cli", created_at: Time.now.utc.iso8601
      )
      each_target(options, args) do |target|
        location = location_of(target)
        location.add(source.with(scope: location.scope))
        @stdout.puts("#{target.label}  attached #{name}")
        true
      end
    end

    def run_push(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      text = utf8(options[:text] || read_stdin)
      return usage_error("no text: pass -m TEXT or pipe it in") unless text

      fetched = ContextSources.parse_output(text)
      each_target(options, args) do |target|
        attached = find(target, name) or next false
        before = attached.snapshot.revision
        written = attached.location.record_text(name, fetched)
        @stdout.puts("#{target.label}  #{name}: #{written.revision == before ? "unchanged" : "new text"} (#{written.revision[0, 12]})")
        true
      end
    end

    def run_ls(options, args)
      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      targets = targets(options, args) or return CLI::Exit::FAILED
      rows = targets.flat_map { |target| rows_for(target) }
      if format == "json"
        @stdout.puts(JSON.pretty_generate(rows))
      elsif rows.empty?
        @stdout.puts("no attached context")
      else
        print_rows(rows, labels: targets.size > 1)
      end
      0
    end

    def run_show(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      targets = targets(options, args) or return CLI::Exit::FAILED
      return usage_error("show takes one target") if targets.size > 1

      attached = find(targets.first, name) or return CLI::Exit::FAILED
      snapshot = attached.snapshot
      if options[:json]
        @stdout.puts(JSON.pretty_generate({ "source" => attached.source.to_h, "snapshot" => snapshot.to_h }))
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
    # source's lock keeps the two from running it at once.
    def run_refresh(options, args)
      name = args.shift
      return usage_error("give the source's NAME") unless name

      each_target(options, args) do |target|
        attached = find(target, name) or next false
        if attached.source.push?
          error_line("#{command_name}: #{name} is pushed (chi context push), it has no command to run")
          next false
        end

        cwd = attached.location.session? || !target.project_root ? target.cwd : target.project_root
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
        location = location_of(target)
        if location.remove(name)
          @stdout.puts("#{target.label}  detached #{name}")
          next true
        end

        project = !target.project? && ContextSources.project_location_for(target.project_root, state_dir: @state_dir)
        if project&.source(name)
          error_line("#{command_name}: #{name} is the project's: chi context rm #{name} --project, or mute it for this session")
        else
          error_line("#{command_name}: no source #{name} for #{target.label}")
        end
        false
      end
    end

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
        own = inside_session
        unless own
          error_line("#{command_name}: give session ids (or unique prefixes), or --project; " \
                     "inside a chi session it's that session")
          return nil
        end
        args = [own]
      end

      resolved = args.uniq.map { |given| session_target(given) }
      resolved.all? ? resolved.uniq : nil
    end

    def project_target
      unless MemoryPaths.in_repo?(@cwd)
        error_line("#{command_name}: --project needs a git repository, and #{@cwd} is in none")
        return nil
      end

      root = MemoryPaths.project_root(@cwd)
      Target.new(session_id: nil, project_root: root, cwd: root, label: "project #{File.basename(root)}")
    end

    def session_target(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      session = Session.load(id, state_dir: @state_dir)
      Target.new(session_id: id, project_root: session.project_root, cwd: session.working_directory, label: id[0, 8])
    rescue ArgumentError => e
      message = e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"
      error_line("#{command_name}: #{message}")
      nil
    end

    # The session chi's execute runs this in (SAMAGOTCHI_PARENT_SESSION;
    # "chi" is a run with no session).
    def inside_session
      id = @env.fetch("SAMAGOTCHI_PARENT_SESSION", "").to_s.strip
      id.empty? || id == "chi" ? nil : id
    end

    # The folder a target's own sources live in.
    def location_of(target)
      if target.project?
        ContextSources.project_location_for(target.project_root, state_dir: @state_dir)
      else
        ContextSources.session_location(target.session_id, state_dir: @state_dir)
      end
    end

    # A source as the target sees it (a session: its own, then its project's).
    # @return [ContextSources::Attached, nil] nil after an error line
    def find(target, name)
      ContextSources.check_name!(name)
      found = if target.project?
                location = location_of(target)
                source = location.source(name)
                source && ContextSources::Attached.new(source: source, location: location, shadowed: false)
              else
                attached_to(target).find { |a| a.name == name }
              end
      error_line("#{command_name}: no source #{name} for #{target.label}") unless found
      found
    end

    def attached_to(target, shadowed: false)
      ContextSources.attached(target.session_id, project_root: target.project_root, state_dir: @state_dir,
                                                 shadowed: shadowed)
    end

    def rows_for(target)
      if target.project?
        location = location_of(target)
        return location.sources.map { |source| row(target, source, location.snapshot(source.name)) }
      end

      own = ContextSources.session_location(target.session_id, state_dir: @state_dir)
      subs = own.subscriptions
      attached_to(target, shadowed: true).map do |a|
        snapshot = a.snapshot
        read = subs[a.name]&.read
        row(target, a.source, snapshot, muted: own.muted?(a.name), shadowed: a.shadowed,
                                        unread: snapshot.text? && read != snapshot.revision)
      end
    end

    def row(target, source, snapshot, muted: nil, shadowed: nil, unread: nil)
      { "target" => target.label, "session_id" => target.session_id, "name" => source.name, "scope" => source.scope,
        "cmd" => source.cmd, "every_seconds" => source.every_seconds, "why" => source.why, "hint" => source.hint,
        "added_by" => source.added_by, "created_at" => source.created_at, "fetched_at" => snapshot.fetched_at,
        "revision" => snapshot.revision, "summary" => snapshot.summary, "error" => snapshot.error,
        "muted" => muted, "shadowed" => shadowed, "unread" => unread }.compact
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
        [*(labels ? [r["target"]] : []), r["name"], r["scope"], kind, age(r["fetched_at"]), state, r["why"].to_s]
      end
      widths = lines.transpose.map { |column| column.map(&:length).max }
      lines.each { |line| @stdout.puts(line.zip(widths).map { |cell, w| cell.ljust(w) }.join("  ").rstrip) }
    end

    def age(iso)
      return "-" unless iso

      seconds = (Time.now - Time.iso8601(iso)).to_i
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

    # Only a pipe or a file is read, as chi note does: a terminal or a
    # socket would hang a script.
    def read_stdin
      return nil if @stdin.respond_to?(:tty?) && @stdin.tty?

      if @stdin.respond_to?(:stat)
        stat = @stdin.stat
        return nil unless stat.pipe? || stat.file?
      end

      @stdin.read
    end

    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end
  end
end
