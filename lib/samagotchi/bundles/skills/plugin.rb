# frozen_string_literal: true

# The skills bundle (docs/plugins.md, The skills bundle): a skill is a memory
# named skill_<name> that holds the steps of a task done with the user
# (docs/memory.md, Skills). The system bundle's identity already tells the
# model to save, follow and update skills; this bundle adds `/skill` for the
# user and keeps an eye on the model's rewrites.
#
# History: before memory_write, write or edit changes a skill's file, the
# file as it was is kept under $XDG_STATE_HOME/samagotchi/plugins/skills/
# history/<scope>/<name>/<UTC time>.md (state, not the memories dir, so
# bundle build and dotfile syncs never see it), history_keep per skill. The
# after_tool_call of that call (calls run one at a time; that event carries
# no call, so the before side stashes it) compares the file on disk and
# shows a line: "skill release updated (+2 −1): …" or "skill release saved
# (project, 14 lines)".
#
# A skill read in this turn is also watched for changes made some other way
# (an execute running sed, a script): after each other tool call, and at the
# turn's end, its file is compared with the content last seen (at the read,
# or after the last write above); a change keeps that content as a version,
# shows the same line and counts as the skill updated.
#
# The nudge (nudge: true), for models that skip a failing step instead of
# fixing the skill: in a turn that read a skill (memory_read of a skill_*
# name, or a read of its file), the first failing tool call after it (an
# execute with "exit: N", N ≠ 0, or with no exit line an Error: line near
# the top; any tool's "[tool] Error: …") steers the model once to find out
# why and fix the skill, unless a skill read was changed already (by any
# tool, see above). A call a guardrail or the user denied (its first line
# "[tool] Error: blocked by guardrail: …", "… denied by guardrail (…): …" or
# "… <the user's answer> It needed approval (…): …") isn't a failed step:
# it says nothing about the skill. At the turn's end, a failed step with no
# change to a skill read gets a notice line.
#
# Settings (config.yml, bundles: skills:):
#   history_keep: 20   older versions kept per skill
#   nudge: true        steer the model once when a skill's step fails
require "date"
require "fileutils"

class Plugin
  WRITE_TOOLS = %w[memory_write write edit].freeze
  NOTICE_WIDTH = 60 # the changed line in an update's notice
  NUDGE = "A step of skill %s failed. Find out why before skipping it; if the skill is out of date, fix it now: " \
          "edit the step that changed in its file (or memory_write the whole skill) and add a Changelog line."
  NOT_FAILURES = %w[memory_read memory_write].freeze
  USAGE = "usage: /skill save [name] [--system] | list | show <name> | diff <name> [N]"

  def initialize(settings = {})
    @history_keep = positive(settings["history_keep"]) || 20
    @nudge = settings.key?("nudge") ? settings["nudge"] != false : true
    @stash = nil
    reset_turn
  end

  def register(chi)
    chi.on(:before_turn) { |_event, _ctx| reset_turn }
    chi.on(:after_turn) { |_event, ctx| after_turn(ctx) }
    chi.on(:before_tool_call) { |event, ctx| before_tool_call(event, ctx) }
    chi.on(:after_tool_call) { |event, ctx| after_tool_call(event, ctx) }
    chi.command "/skill", "skills (steps of a task we did): save [name] [--system], list, show <name>, diff <name> [N]",
                anytime: true do |args, ctx|
      command(args.to_s.strip, ctx)
    end
  end

  private

  # --- a skill's file changes ----------------------------------------------

  def before_tool_call(event, ctx)
    @stash = nil
    tool = event.dig(:call, :name).to_s
    note_read(tool, event)
    return unless WRITE_TOOLS.include?(tool)

    path = Array(event.dig(:targets, :paths)).find { |target| skill_at(target) }
    return unless path

    scope, name = skill_at(path)
    old = File.file?(path) ? File.read(path) : nil
    keep_version(ctx, scope, name, old) if old
    @stash = { tool: tool, path: File.expand_path(path), scope: scope, name: name, old: old }
  end

  # Success is the file changed on disk, whatever the output says. A call
  # that didn't match the stash (a cancelled turn fires no before) drops it.
  def after_tool_call(event, ctx)
    stash = @stash
    @stash = nil
    stash = nil unless stash && stash[:tool] == event[:tool].to_s
    changed_elsewhere(ctx) unless stash
    step_failed(event, ctx) if @nudge && !@read.empty?
    return unless stash

    now = File.file?(stash[:path]) ? File.read(stash[:path]) : nil
    return if now.nil? || now == stash[:old]

    @written |= [stash[:name]]
    @seen[stash[:name]] = { path: stash[:path], scope: stash[:scope], content: now }
    ctx.notify(change_notice(stash, now))
  end

  # A skill read this turn whose file differs from the content last seen was
  # changed by something other than the write tools (an execute's sed, say):
  # keep what was there as a version, show the change, count the skill as
  # updated (any change counts, the user's own edit too). A file gone since
  # is left alone.
  def changed_elsewhere(ctx)
    @seen.each do |name, seen|
      now = File.file?(seen[:path]) ? File.read(seen[:path]) : nil
      next if now.nil? || now == seen[:content]

      keep_version(ctx, seen[:scope], name, seen[:content]) if seen[:content]
      ctx.notify(change_notice({ name: name, scope: seen[:scope], old: seen[:content] }, now))
      seen[:content] = now
      @written |= [name]
    end
  rescue SystemCallError => e
    ctx.log.warn(:watch_failed, error: e.class.name, msg: e.message)
  end

  def change_notice(stash, now)
    name = stash[:name]
    return "skill #{name} saved (#{stash[:scope]}, #{now.lines.size} lines)" unless stash[:old]

    ops = line_diff(stash[:old].lines(chomp: true), now.lines(chomp: true))
    added = ops.count { |op, _| op == :add }
    removed = ops.count { |op, _| op == :del }
    first = ops.find { |op, _| op == :add } || ops.find { |op, _| op == :del }
    line = first ? cut(first.last.strip) : ""
    "skill #{name} updated (+#{added} −#{removed})#{": #{line}" unless line.empty?} · /skill diff #{name}"
  end

  # --- the nudge ------------------------------------------------------------

  def reset_turn
    @read = []      # skills read this turn, in order
    @seen = {}      # of those, name => {path:, scope:, content:} last seen
    @written = []   # skills changed this turn
    @failed = false # a step failed after a skill was read
    @nudged = false
  end

  def note_read(tool, event)
    found = case tool
            when "memory_read"
              scope = event.dig(:call, :scope).to_s.strip
              scope = nil unless memory_dirs.key?(scope)
              # A skill not written yet is watched where memory_write would
              # put it by default: the read scope, else project.
              event.dig(:call, :content).to_s.split(",").map(&:strip).select { |entry| entry.start_with?("skill_") }
                   .filter_map do |entry|
                     name = skill_name(entry) or next
                     unwritten = File.join(memory_dirs[scope || "project"], "skill_#{name}.md")
                     [name, skill_path(name, scope: scope) || unwritten]
                   end
            when "read"
              Array(event.dig(:targets, :paths)).filter_map { |path| (at = skill_at(path)) && [at.last, path] }
            else []
            end
    found.each { |name, path| watch(name, path) }
    @read |= found.map(&:first)
  end

  # Remember a read skill's content (nil: not written yet) the first time in
  # a turn: a later read mustn't hide a change made in between.
  def watch(name, path)
    return if @seen.key?(name) || path.nil?

    content = File.file?(path) ? File.read(path) : nil
    @seen[name] = { path: File.expand_path(path), scope: skill_at(path)&.first, content: content }
  rescue SystemCallError
    nil
  end

  # A failed step is a call whose status (core's, from the full output) is
  # error: a denied call is blocked, a stopped task_wait stopped.
  def step_failed(event, ctx)
    return if NOT_FAILURES.include?(event[:tool].to_s) || event[:status] != "error"

    @failed = true
    return if @nudged || @read.any? { |name| @written.include?(name) }

    @nudged = ctx.steer(format(NUDGE, @read.join(", ")))
  end

  def after_turn(ctx)
    changed_elsewhere(ctx)
    return unless @nudge && @failed

    missed = @read - @written
    return unless missed.size == @read.size

    ctx.notify("skill #{missed.join(", ")} was followed, a step failed, the skill wasn't updated")
  end

  # --- history ---------------------------------------------------------------

  # Keep +content+ as the newest version, unless it is the newest already (a
  # denied or failed write leaves the file as it was).
  def keep_version(ctx, scope, name, content)
    dir = history_dir(ctx, scope, name)
    FileUtils.mkdir_p(dir)
    newest = versions(dir).first
    return if newest && File.read(newest) == content

    stamp = Time.now.utc.strftime("%Y%m%dT%H%M%S.%6NZ")
    path = File.join(dir, "#{stamp}.md")
    Samagotchi::AtomicFile.write(path, content)
    versions(dir).drop(@history_keep).each { |old| File.delete(old) }
  rescue SystemCallError => e
    ctx.log.warn(:history_failed, skill: name, error: e.class.name, msg: e.message)
  end

  # history/system/<name>, history/project-<project folder>/<name>
  def history_dir(ctx, scope, name)
    key = scope == "system" ? "system" : "project-#{File.basename(memory_dirs["project"])}"
    File.join(ctx.data_dir, "history", key, name)
  end

  # The kept versions, newest first.
  def versions(dir) = Dir.glob(File.join(dir, "*.md")).sort.reverse

  # --- /skill ----------------------------------------------------------------

  def command(args, ctx)
    verb, rest = args.split(/\s+/, 2)
    rest = rest.to_s.strip
    case verb
    when "save" then save(rest, ctx)
    when "list" then rest.empty? ? list : USAGE
    when "show" then show(rest)
    when "diff" then diff(rest, ctx)
    else USAGE
    end
  end

  # /skill save [name] [--system]: asks the model, in this session, to save
  # what was just done (the model has seen the commands; a side answer
  # wouldn't). The request runs as a turn; sent while a turn runs it joins
  # that turn at its next step, and the request says to finish the task
  # first. A REPL session (--no-shared) takes no messages: the request is
  # shown for the user to send.
  def save(rest, ctx)
    words = rest.split
    scope = words.delete("--system") ? "system" : "project"
    return USAGE if words.size > 1 || words.any? { |word| word.start_with?("-") }

    name = words.first && skill_name(words.first)
    return "/skill save: a name is letters, digits, _ and - (got #{words.first})" if words.first && !name

    request = save_request(name, scope, exists: name && skill_path(name))
    begin
      ctx.sessions.send(ctx.session_id, request)
    rescue Samagotchi::Plugin::Sessions::Error => e
      return "/skill save: #{e.message}. Send this yourself:\n\n#{request}"
    end
    what = name ? "skill #{name}" : "a skill"
    "asked chi to save #{what} (#{scope} scope); a running turn gets it at its next step"
  end

  def save_request(name, scope, exists:)
    target = name ? "skill `skill_#{name}`" : "a skill named `skill_<name>` (a short name for the task)"
    update = exists ? " It exists already: read it, keep what still holds, fix what changed, add a Changelog line." : ""
    <<~TEXT.strip
      Save what we just did as #{target} with memory_write, scope #{scope}.#{update} If you are still in the middle of the task, finish it first.
      Content: plain Markdown, no frontmatter:

      # Skill: #{name || "<name>"}

      ## Steps
      1. …
      ## Gotchas
      - …
      ## Changelog
      - #{Date.today.iso8601} created

      Steps are the commands and checks that worked, in order, with the real file and command names; a step that must pass says "stop if it fails". Dead ends and surprises go under Gotchas. Give memory_write a description: one line that starts with what this task is and names its main steps, in this task's own words, so the skill is found next time. Then show the skill briefly.
    TEXT
  end

  # /skill list: the skill_* memories of both scopes, with their index line's
  # date and description.
  def list
    skills = memory_dirs.flat_map do |scope, dir|
      index = index_lines(dir)
      Dir.glob(File.join(dir, "skill_*.md")).filter_map do |path|
        name = File.basename(path, ".md").delete_prefix("skill_")
        next unless skill_name(name) == name

        date, description = index.fetch("skill_#{name}", [nil, nil])
        line = "#{name} · #{scope}"
        line << " · #{date}" if date
        line << " — #{description}" if description
        line
      end.sort
    end
    return "no skills yet: after a task we did together, /skill save [name]" if skills.empty?

    "skills:\n#{skills.map { |line| "  #{line}" }.join("\n")}"
  end

  # /skill show <name>: the skill as saved (project first).
  def show(rest)
    name = skill_name(rest)
    return USAGE unless name

    path = skill_path(name) or return "no skill #{name} (/skill list shows them)"
    "skill #{name} · #{scope_of(path)}\n\n#{File.read(path).strip}"
  end

  # /skill diff <name> [N]: the skill now against its N-th newest kept
  # version (1, the one before the last change, by default), unified.
  def diff(rest, ctx)
    word, back = rest.split
    name = skill_name(word)
    n = back ? Integer(back, exception: false) : 1
    return USAGE unless name && n&.positive? && rest.split.size <= 2

    path = skill_path(name) or return "no skill #{name} (/skill list shows them)"
    kept = versions(history_dir(ctx, scope_of(path), name))
    return "skill #{name} has no older version yet" if kept.empty?
    return "skill #{name} has #{kept.size} older version#{"s" if kept.size > 1} (/skill diff #{name} 1..#{kept.size})" if n > kept.size

    old = kept[n - 1]
    body = unified(File.read(old).lines(chomp: true), File.read(path).lines(chomp: true))
    return "skill #{name} is the same as version #{n}" if body.empty?

    "--- skill_#{name} (#{version_time(old)})\n+++ skill_#{name} (now)\n#{body}"
  end

  CONTEXT = 3

  # Hunks with CONTEXT lines around each change, as diff -u prints them.
  def unified(a, b)
    ops = line_diff(a, b)
    changed = ops.each_index.reject { |k| ops[k].first == :eq }
    return "" if changed.empty?

    # Group changes whose context would touch into one hunk.
    groups = changed.slice_when { |x, y| y - x > 2 * CONTEXT + 1 }.to_a
    old_at = new_at = 0
    positions = ops.map do |op, _|
      at = [old_at, new_at]
      old_at += 1 unless op == :add
      new_at += 1 unless op == :del
      at
    end
    groups.map do |group|
      from = [group.first - CONTEXT, 0].max
      to = [group.last + CONTEXT, ops.size - 1].min
      slice = ops[from..to]
      old_count = slice.count { |op, _| op != :add }
      new_count = slice.count { |op, _| op != :del }
      old_start, new_start = positions[from]
      header = "@@ -#{range(old_start, old_count)} +#{range(new_start, new_count)} @@"
      lines = slice.map { |op, line| "#{{ eq: " ", del: "-", add: "+" }[op]}#{line}" }
      [header, *lines].join("\n")
    end.join("\n")
  end

  # diff -u's "start,count" (1-based; an empty side names the line before).
  def range(start, count)
    first = count.zero? ? start : start + 1
    count == 1 ? first.to_s : "#{first},#{count}"
  end

  # "2026-09-30 10:22 UTC" from a version's file name.
  def version_time(path)
    stamp = File.basename(path, ".md")
    match = stamp.match(/\A(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)/)
    match ? "#{match[1]}-#{match[2]}-#{match[3]} #{match[4]}:#{match[5]} UTC" : stamp
  end

  # --- skills on disk --------------------------------------------------------

  # "release", "skill_release", "Release-Notes" → "release", "release-notes";
  # nil for anything else.
  def skill_name(word)
    name = word.to_s.downcase.delete_suffix(".md").delete_prefix("skill_")
    name.match?(/\A[a-z0-9][a-z0-9_-]*\z/) ? name : nil
  end

  # The memories dir of each scope, as memory_read/memory_write resolve it.
  def memory_dirs
    %w[project system].to_h { |scope| [scope, File.expand_path(Samagotchi::Tools::MemoryRead.memories_dir(scope))] }
  end

  # The skill's file, project first (as memory_read looks), or nil.
  def skill_path(name, scope: nil)
    dirs = scope ? memory_dirs.slice(scope) : memory_dirs
    dirs.each_value do |dir|
      path = File.join(dir, "skill_#{name}.md")
      return path if File.file?(path)
    end
    nil
  end

  # [scope, name] when +path+ is a skill_<name>.md right in a memories dir.
  def skill_at(path)
    path = File.expand_path(path.to_s)
    scope = memory_dirs.key(File.dirname(path))
    name = File.basename(path, ".md").delete_prefix("skill_")
    return nil unless scope && File.basename(path) == "skill_#{name}.md" && skill_name(name) == name

    [scope, name]
  end

  def scope_of(path) = memory_dirs.key(File.dirname(path)) || "?"

  # The managed index.md lines, {name => [date, description]}:
  # "- **name** · scope · date · bytes — description".
  def index_lines(dir)
    path = File.join(dir, "index.md")
    return {} unless File.file?(path)

    File.readlines(path, chomp: true).each_with_object({}) do |line, lines|
      match = line.match(/\A- \*\*(?<name>[^*]+)\*\* · [^·]+ · (?<date>[^·]+?) · [^—]+?(?: — (?<description>.+))?\z/)
      lines[match[:name]] = [match[:date].strip, match[:description]&.strip] if match
    end
  end

  # --- helpers ---------------------------------------------------------------

  # The lines of +a+ and +b+ as [:eq|:del|:add, line], in order (a longest
  # common subsequence; skills are short).
  def line_diff(a, b)
    lcs = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
    (a.size - 1).downto(0) do |i|
      (b.size - 1).downto(0) do |j|
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : [lcs[i + 1][j], lcs[i][j + 1]].max
      end
    end
    ops = []
    i = j = 0
    while i < a.size && j < b.size
      if a[i] == b[j]
        ops << [:eq, a[i]]
        i += 1
        j += 1
      elsif lcs[i + 1][j] >= lcs[i][j + 1]
        ops << [:del, a[i]]
        i += 1
      else
        ops << [:add, b[j]]
        j += 1
      end
    end
    ops.concat(a[i..].map { |line| [:del, line] }, b[j..].map { |line| [:add, line] })
  end

  def cut(text) = text.length > NOTICE_WIDTH ? "#{text[0, NOTICE_WIDTH - 1]}…" : text

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
