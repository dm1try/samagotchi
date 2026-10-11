# frozen_string_literal: true

# The slow-commands bundle (docs/plugins.md, The slow-commands bundle): an
# `execute` that ran past its limit (or close to it) is remembered for the
# project, and the next identical `execute` is denied with advice: start it
# with task_create, then task_wait with a timeout that fits.
#
# A command is keyed by its project (the session's git checkout, else its
# working directory) and its text: the ShellLex words and operators joined
# by one space, the call's cwd: folded in as a leading `cd <dir> &&`
# (relative to the project), and a trailing output filter dropped (a final
# 2>&1, `| tail …`, `| head …`, `| grep …`: they don't change how long it
# runs). Arguments stay: `bundle exec rspec` (the suite) is not
# `bundle exec rspec spec/x_spec.rb`. Wrappers a model adds by habit are
# dropped at the start of each simple command (after &&, ||, ;, a newline,
# so after a leading `cd X &&` too): `time [-p]` and `timeout`/`gtimeout`
# with its options and duration. `X=…` assignments stay, sorted (they can
# pick the target or the mode: SPEC=…, RAILS_ENV=…), except NO_COLOR,
# FORCE_COLOR, CI and TERM, which never change what runs; a plain
# `env X=… cmd` is `X=… cmd`, an `env` with -C/-i/-u (or any other option)
# stays as typed. The entry's `shown` is the last run as typed. Input that ends inside a quote, $(…)
# or heredoc is never recorded, nor one with a $(…), backticks or a heredoc
# cat/tee read as data: ShellLex makes those one placeholder, so different
# commands would share a key.
#
# after_tool_call records: timed out (killed at the limit), handed over as
# a task at the limit (Execute::HANDED_OVER), or ran at least warn_ratio of
# the limit -> slow; ran under half of it with exit 0 -> the entry is dropped
# (a fast failure says nothing about the suite's length), unless a trailing
# filter was stripped: `rspec | tail` exits with tail's 0 when rspec failed,
# and a `| head` can end it early. A stopped or
# denied call records nothing. A key is denied once per turn: the model
# running it again in the same turn is let through (maybe it got faster),
# and that run records the new truth. before_turn resets it.
#
# Store: <data_dir>/commands.json, a list of {project, command (the key),
# shown, slow_at, limit_s, elapsed_s, timed_out}, re-read on each lookup (another session's
# record counts at once), written whole (AtomicFile), entries older than
# ttl_days dropped on write.
#
# The advice names how long a finished task of the same command took: the
# project's tmp/tasks/*/task.json read as files (never TaskRuntime's
# list_records, which mkdirs, runs ps and writes), the exit_code file's
# mtime minus started_at (finished_at is when chi noticed). The exit_code
# file is the record's exit_code_path (a handed-over execute keeps it in
# the state dir), else the one next to task.json.
#
# A `timeout N` over the execute limit is denied up front (no history
# needed) when execute.on_timeout is kill: execute stops it first. Under
# task (the default) it runs on as a task until timeout fires: nothing to
# say. Exit codes mean what they always do here: 124/137 (timeout's) are
# no sign of a slow command by themselves.
#
# Settings (config.yml, bundles: slow-commands:):
#   mode: deny        deny | notify (warn the user, never deny)
#   warn_ratio: 0.8   a run this share of the limit or longer is slow
#   ttl_days: 14      entries older than this are forgotten
#
# /slow-commands lists this project's entries; /slow-commands forget <n|all>
# drops them.
require "json"
require "pathname"
require "time"
require "samagotchi/atomic_file"
require "samagotchi/config"
require "samagotchi/guardrails/shell_lex"
require "samagotchi/tools/execute"
require "samagotchi/tools/task_runtime"

class Plugin
  SOURCE = "bundle slow-commands"
  FILE = "commands.json"
  FILTERS = %w[tail head grep].freeze
  TIMED_OUT = /\A#{Regexp.escape(Samagotchi::Tools::Execute::TIMEOUT_PREFIX)} (\d+)s/
  # Still running at the limit, handed over as a task (chi >= 0.59.0).
  HANDED_OVER = /\A#{Regexp.escape(Samagotchi::Tools::Execute::HANDED_OVER)} (\d+)s limit/
  STOPPED = [Samagotchi::Tools::Execute::STOPPED_BY_USER, Samagotchi::Tools::Execute::NOT_RUN_ON_STOP].freeze
  LEX = Samagotchi::Guardrails::ShellLex
  SHORT_CHARS = 60
  WAIT_DEFAULT = 600
  # Where a simple command starts: a wrapper there is dropped from the key.
  STARTS = ["&&", "||", ";", "\n"].freeze
  ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/
  # Assignments that never change what runs: not part of the key.
  NEUTRAL_VARS = %w[NO_COLOR FORCE_COLOR CI TERM].freeze
  TIMEOUTS = %w[timeout gtimeout].freeze
  # timeout's options: those that take a value, and the flags.
  TIMEOUT_VALUE_OPTIONS = %w[-s -k --signal --kill-after].freeze
  TIMEOUT_FLAGS = %w[--foreground --preserve-status -v --verbose].freeze
  DURATION = /\A(\d+(?:\.\d+)?|\.\d+)([smhd]?)\z/
  UNIT_SECONDS = { "" => 1, "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

  def initialize(settings = {})
    @mode = settings["mode"].to_s == "notify" ? :notify : :deny
    ratio = Float(settings["warn_ratio"].to_s, exception: false)
    @warn_ratio = ratio && ratio.positive? && ratio <= 1 ? ratio : 0.8
    @ttl_days = positive(settings["ttl_days"]) || 14
    reset
  end

  def register(chi)
    chi.on(:before_turn) { |_event| reset }
    chi.on(:before_tool_call) { |event, ctx| before(event, ctx) }
    chi.on(:after_tool_call) { |event, ctx| after(event, ctx) }
    chi.command "/slow-commands", "commands that ran past the execute limit here; forget <n|all> drops them",
                anytime: true do |args, ctx|
      command(args.to_s.strip, ctx)
    end
  end

  # The command text as the store keys it, or nil when it can't be keyed
  # (empty, unterminated). +cwd+: where it runs (nil: the session's).
  def self.normalize(text, cwd:, project:, base:)
    text = text.to_s.strip
    return nil if text.empty? || LEX.unterminated?(text)

    tokens = LEX.lex(text)
    return nil if tokens.any? { |kind, value| kind == :word && value.include?("\0") }

    tokens = unwrap(tokens).first
    tokens = strip_filters(tokens)
    return nil if tokens.empty?

    words = tokens.map { |kind, value| kind == :op ? value.tr("\n", ";") : quote(value) }
    dir = folded_dir(cwd, project: project, base: base)
    words = ["cd", quote(dir), "&&", *words] if dir
    words.join(" ")
  end

  # The tokens without the wrappers at the start of each simple command
  # (time, timeout), assignments sorted and the neutral ones dropped, and
  # the seconds of every timeout dropped.
  # @return [Array(Array, Array<Float>)]
  def self.unwrap(tokens)
    durations = []
    out = []
    segment = []
    flush = lambda do
      words, seconds = unwrap_command(segment)
      durations.concat(seconds)
      out.concat(words)
      segment = []
    end
    tokens.each do |token|
      if token[0] == :op && STARTS.include?(token[1])
        flush.call
        out << token
      else
        segment << token
      end
    end
    flush.call
    [out, durations]
  end

  # One simple command's tokens (it may hold a | or & further on: only its
  # start is looked at).
  def self.unwrap_command(tokens)
    rest = tokens.dup
    assignments = []
    durations = []
    loop do
      assignments << rest.shift[1] while word?(rest.first) && rest.first[1].match?(ASSIGNMENT)
      head = word?(rest.first) ? rest.first[1] : nil
      if head == "time"
        rest.shift
        rest.shift if word?(rest.first) && rest.first[1] == "-p"
      elsif head == "env" && word?(rest[1]) && !rest[1][1].start_with?("-")
        rest.shift
      elsif TIMEOUTS.include?(head) && (skipped = timeout_length(rest))
        count, seconds = skipped
        rest.shift(count)
        durations << seconds
      else
        break
      end
    end
    kept = assignments.reject { |a| NEUTRAL_VARS.include?(a.split("=", 2).first) }.sort
    [kept.map { |a| [:word, a, ""] } + rest, durations]
  end

  # [words to drop, seconds] for a `timeout [opts] DUR` at the start of
  # +tokens+, or nil when it can't be read (then it stays in the key).
  def self.timeout_length(tokens)
    i = 1
    while word?(tokens[i]) && tokens[i][1].start_with?("-")
      option = tokens[i][1]
      if TIMEOUT_FLAGS.include?(option) || option.start_with?("--signal=", "--kill-after=")
        i += 1
      elsif TIMEOUT_VALUE_OPTIONS.include?(option)
        i += 2
      else
        return nil
      end
    end
    seconds = word?(tokens[i]) ? duration_seconds(tokens[i][1]) : nil
    seconds && word?(tokens[i + 1]) ? [i + 1, seconds] : nil
  end

  def self.duration_seconds(text)
    match = DURATION.match(text)
    match ? Float(match[1]) * UNIT_SECONDS.fetch(match[2]) : nil
  end

  def self.word?(token) = token && token[0] == :word

  # The longest `timeout N` (seconds) at the start of a simple command in
  # +text+, or nil for none (or text that can't be keyed).
  def self.timeout_seconds(text)
    text = text.to_s.strip
    return nil if text.empty? || LEX.unterminated?(text)

    unwrap(LEX.lex(text)).last.max
  end

  # Whether the key dropped a trailing output filter (2>&1, | tail …):
  # the exit code is then the filter's, and the run may have been cut short.
  def self.filtered?(text)
    tokens = LEX.lex(text.to_s.strip)
    tokens.pop while tokens.last && tokens.last[0] == :op && [";", "\n"].include?(tokens.last[1])
    strip_filters(tokens).size != tokens.size
  end

  # Drops a trailing 2>&1 word and `| tail/head/grep …` filters, and a
  # trailing ; or newline, until none is left.
  def self.strip_filters(tokens)
    tokens = tokens.dup
    loop do
      before = tokens.size
      tokens.pop while tokens.last && tokens.last[0] == :op && [";", "\n"].include?(tokens.last[1])
      tokens.pop if tokens.last && tokens.last[0] == :word && tokens.last[1] == "2>&1"
      pipe = tokens.rindex { |kind, value| kind == :op && value == "|" }
      if pipe && tokens[(pipe + 1)..].all? { |kind, _| kind == :word } && FILTERS.include?(tokens[pipe + 1]&.at(1))
        tokens = tokens[0...pipe]
      end
      return tokens if tokens.size == before
    end
  end

  def self.quote(word)
    word.empty? || word.match?(/[\s'"]/) ? "'#{word.gsub("'", "'\\\\''")}'" : word
  end

  # The run dir relative to +project+, or nil for the project itself.
  def self.folded_dir(cwd, project:, base:)
    dir = File.expand_path(cwd.to_s.strip.empty? ? base : cwd.to_s.strip, base)
    rel = Pathname.new(dir).relative_path_from(Pathname.new(File.expand_path(project))).to_s
    rel == "." ? nil : rel
  rescue ArgumentError
    dir
  end

  private

  def reset
    @denied = {}
  end

  def before(event, ctx)
    call = event[:call]
    verdict = event[:guardrail]
    return unless call.is_a?(Hash) && call[:name].to_s == Samagotchi::Tools::Execute::NAME && verdict
    return if verdict.deny?

    key = key_for(call, ctx)
    return unless key
    return if @denied[key]
    return if over_limit_timeout(call, verdict, ctx, key)

    entry = live_entries(ctx).find { |e| e["project"] == key[0] && e["command"] == key[1] }
    return unless entry

    @denied[key] = true
    if @mode == :notify
      ctx.notify("execute #{short(call[:content])}: #{what(entry)} before", level: :warn)
      return
    end

    verdict.deny!("slow command", source: SOURCE, advice: advice(entry, ctx, key))
    ctx.notify("execute #{short(call[:content])}: #{what(entry)} before, denied", level: :warn)
  end

  # A `timeout N` over the limit while execute kills at it (on_timeout:
  # kill): N never takes effect. Denied once a turn, like a slow entry.
  # @return [Boolean] whether it was handled
  def over_limit_timeout(call, verdict, ctx, key)
    return false unless Samagotchi::Config.get("execute.on_timeout").to_s == "kill"

    seconds = self.class.timeout_seconds(call[:content])
    limit = Samagotchi::Tools::Execute.timeout_seconds
    return false unless seconds && seconds > limit

    @denied[key] = true
    wait = [WAIT_DEFAULT, seconds.ceil].max
    line = "execute #{short(call[:content])}: timeout #{duration(seconds.ceil)} is past the #{limit} s limit"
    if @mode == :notify
      ctx.notify(line, level: :warn)
    else
      verdict.deny!("timeout past the execute limit", source: SOURCE,
                                                      advice: "execute stops a command at #{limit} s, so its timeout " \
                                                              "(#{duration(seconds.ceil)}) never takes effect. Start it " \
                                                              "with task_create, then task_wait (timeout #{wait}).")
      ctx.notify("#{line}, denied", level: :warn)
    end
    true
  end

  def after(event, ctx)
    call = event[:call]
    return unless event[:tool].to_s == Samagotchi::Tools::Execute::NAME && call.is_a?(Hash)

    elapsed_ms = event[:elapsed_ms]
    result = event[:result].to_s
    return if elapsed_ms.nil? || STOPPED.any? { |text| result.start_with?(text) }

    key = key_for(call, ctx)
    return unless key

    limit = Samagotchi::Tools::Execute.timeout_seconds
    shown = call[:content].to_s.strip
    if (timed_out = result[TIMED_OUT, 1] || result[HANDED_OVER, 1])
      remember(ctx, key, shown, limit_s: timed_out.to_i, elapsed_s: timed_out.to_i, timed_out: true)
    elsif elapsed_ms >= @warn_ratio * limit * 1000
      remember(ctx, key, shown, limit_s: limit, elapsed_s: (elapsed_ms / 1000.0).round, timed_out: false)
    elsif elapsed_ms < 0.5 * limit * 1000 && exit_zero?(result) && !self.class.filtered?(call[:content])
      forget_key(ctx, key)
    end
  end

  def key_for(call, ctx)
    project = project_of(ctx)
    command = self.class.normalize(call[:content], cwd: call[:cwd], project: project, base: ctx.cwd)
    command ? [project, command] : nil
  end

  def project_of(ctx) = ctx.repo_root || ctx.cwd

  def exit_zero?(result)
    result.scan(/^exit: (-?\d+)/).last == ["0"]
  end

  # --- the store ---

  def store_path(ctx) = File.join(ctx.data_dir, FILE)

  def entries(ctx)
    list = JSON.parse(File.read(store_path(ctx)))
    list.is_a?(Array) ? list.select { |e| e.is_a?(Hash) && e["project"] && e["command"] } : []
  rescue Errno::ENOENT, JSON::ParserError
    []
  end

  def live_entries(ctx) = entries(ctx).select { |e| live?(e) }

  def live?(entry)
    Time.iso8601(entry["slow_at"].to_s) > Time.now - (@ttl_days * 86_400)
  rescue ArgumentError
    false
  end

  def save(ctx, list)
    Samagotchi::AtomicFile.write(store_path(ctx), "#{JSON.pretty_generate(list.select { |e| live?(e) })}\n")
  end

  # +shown+: the command as this run typed it (the list shows it).
  def remember(ctx, key, shown, limit_s:, elapsed_s:, timed_out:)
    list = entries(ctx).reject { |e| e["project"] == key[0] && e["command"] == key[1] }
    list << { "project" => key[0], "command" => key[1], "shown" => shown, "slow_at" => Time.now.utc.iso8601,
              "limit_s" => limit_s, "elapsed_s" => elapsed_s, "timed_out" => timed_out }
    save(ctx, list)
  end

  def forget_key(ctx, key)
    list = entries(ctx)
    kept = list.reject { |e| e["project"] == key[0] && e["command"] == key[1] }
    save(ctx, kept) if kept.size != list.size
  end

  # --- the deny's advice ---

  def advice(entry, ctx, key)
    took = task_duration(ctx, key)
    wait = took ? [WAIT_DEFAULT, ((took * 1.5) / 60.0).ceil * 60].max : WAIT_DEFAULT
    date = entry["slow_at"].to_s[0, 10]
    seen = if entry["timed_out"]
             "This command ran past the execute limit (#{entry["limit_s"]} s) here on #{date}."
           else
             "This command took #{duration(entry["elapsed_s"])} of the execute limit (#{entry["limit_s"]} s) here on #{date}."
           end
    text = "#{seen} Start it with task_create, then task_wait (timeout #{wait})."
    took ? "#{text} A finished task of this command took #{duration(took)}." : text
  end

  # Seconds the newest finished (exit 0) task of this key took, or nil.
  def task_duration(ctx, key)
    roots = [ctx.cwd, project_of(ctx)].uniq
    records = roots.flat_map do |root|
      Dir.glob(File.join(root, Samagotchi::Tools::TaskRuntime::TASKS_DIR, "*", "task.json"))
    end.uniq
    found = records.filter_map { |path| finished_task(path, ctx, key) }
    found.max_by(&:first)&.last
  end

  # [started_at, seconds] for a task record of +key+ that ended with exit 0.
  def finished_task(path, ctx, key)
    record = JSON.parse(File.read(path))
    exit_code = record["exit_code_path"].to_s
    exit_code = File.join(File.dirname(path), Samagotchi::Tools::TaskRuntime::EXIT_CODE_FILENAME) unless File.absolute_path?(exit_code)
    return nil unless File.file?(exit_code) && File.read(exit_code).strip == "0"

    command = self.class.normalize(record["command"], cwd: record["cwd"], project: key[0], base: ctx.cwd)
    return nil unless command == key[1]

    started = Time.iso8601(record["started_at"].to_s)
    seconds = (File.mtime(exit_code) - started).round
    seconds.negative? ? nil : [started, seconds]
  rescue StandardError
    nil
  end

  # --- /slow-commands ---

  def command(args, ctx)
    project = project_of(ctx)
    mine = live_entries(ctx).select { |e| e["project"] == project }.sort_by { |e| e["slow_at"].to_s }
    case args
    when ""
      return "slow-commands: none recorded for #{project}" if mine.empty?

      lines = mine.each_with_index.map do |e, i|
        "#{i + 1}. #{shown(e)}: #{what(e)} (#{e["slow_at"].to_s[0, 10]})"
      end
      "slow-commands in #{project}:\n#{lines.join("\n")}\n/slow-commands forget <n|all> drops an entry"
    when /\Aforget\s+(all|\d+)\z/
      which = Regexp.last_match(1)
      drop = which == "all" ? mine : [mine[which.to_i - 1]].compact
      return "slow-commands: no entry #{which} (/slow-commands lists them)" if drop.empty?

      save(ctx, entries(ctx).reject { |e| drop.any? { |d| d["project"] == e["project"] && d["command"] == e["command"] } })
      "slow-commands: forgot #{drop.size == 1 ? shown(drop.first) : "#{drop.size} commands"}"
    else
      "usage: /slow-commands (list this project's slow commands), /slow-commands forget <n|all>"
    end
  end

  # --- text ---

  # The command as last typed; an entry from 0.1.0 has only its key.
  def shown(entry) = entry["shown"].to_s.empty? ? entry["command"] : entry["shown"]

  def what(entry)
    entry["timed_out"] ? "ran past #{entry["limit_s"]} s" : "took #{duration(entry["elapsed_s"])} of #{entry["limit_s"]} s"
  end

  def duration(seconds)
    seconds = seconds.to_i
    seconds < 60 ? "#{seconds}s" : "#{seconds / 60}m#{format("%02d", seconds % 60)}s"
  end

  def short(command)
    text = command.to_s
    text.length > SHORT_CHARS ? "#{text[0, SHORT_CHARS - 1]}…" : text
  end

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
