# frozen_string_literal: true

# The coordinator bundle (docs/plugins.md, The coordinator bundle): chi as a
# coordinator of parallel work. Its skill_coordinator memory holds the steps
# (split the work, one worktree and a wait: false delegate per task, check
# each report, ask before each merge); this plugin adds two commands.
#
# /children [all] shows this session's children as a card, newest first:
# state, branch, the last reply and whether it was reported (ChildrenStatus
# through ctx.sessions.children), with a Stop button per running or waiting
# child and Refresh. `all` adds archived children. The card has one id, so
# Refresh and Stop replace it. It is read on demand: no thread, no polling.
#
# /children stop <id> stops one of this session's own children
# (ctx.sessions.stop, by session id) and shows the card again.
#
# /coordinate <goal> asks the model, in this session, to follow the skill
# for the goal. A REPL session (--no-shared) takes no messages: the request
# is shown for the user to send.
#
# /coordinate resume picks up a coordinator handoff: the open handoff_*
# memories of this project (an index line whose description doesn't start
# with DONE, its file there). One: the model is asked to resume it (the
# skill's step 0); several: a card with a Resume action each
# (/coordinate resume <name>); none: says so. It reads the project's
# memories folder, nothing else.
#
# A child is asked before it changes anything outside its worktree by chi
# itself (the core child-boundary guardrail), in every mode: nothing to set up.
class Plugin
  CARD_ID = "children"
  # A card takes 6 actions: Refresh and up to 5 Stops.
  MAX_STOPS = 5
  STOPPABLE = %w[running waiting].freeze
  TEXT_CHARS = 80
  USAGE = "usage: /children [all] | /children stop <id>"
  COORDINATE_USAGE = "usage: /coordinate <goal> — chi splits it into tasks, one child session and worktree each; " \
                     "/coordinate resume [name] — pick up an open handoff"
  RESUME_CARD_ID = "coordinate-resume"
  # A card takes 6 actions.
  MAX_RESUMES = 6
  HANDOFF_LINE = /^- \*\*(handoff_[^*\s]+)\*\*(.*)$/

  def initialize(_settings = {}); end

  def register(chi)
    chi.command "/children", "this session's child sessions: state, branch, last reply; all, stop <id>",
                anytime: true do |args, ctx|
      children_command(args.to_s.strip, ctx)
    end
    chi.command "/coordinate", "run work in parallel: chi splits <goal> into tasks, each in a child session and worktree; " \
                               "resume: pick up an open handoff",
                anytime: true do |args, ctx|
      coordinate(args.to_s.strip, ctx)
    end
  end

  private

  def children_command(args, ctx)
    verb, rest = args.split(/\s+/, 2)
    case verb
    when nil then show(ctx, all: false)
    when "all" then rest.to_s.empty? ? show(ctx, all: true) : USAGE
    when "stop" then rest.to_s.strip.empty? ? USAGE : stop(rest.strip, ctx)
    else USAGE
    end
  end

  # The card, made or replaced; nil, so the command adds no text of its own.
  def show(ctx, all:, note: nil)
    children = ctx.sessions.children(all: all)
    title = "children of #{ctx.session_id.to_s[0, 8]}"
    title += " (#{children.size})" unless children.empty?
    body = children.empty? ? "no children" : children.map { |child| line(child) }.join("\n")
    body = "#{note}\n\n#{body}" if note
    refresh = all ? "/children all" : "/children"
    stops = children.select { |child| STOPPABLE.include?(child[:state]) }.first(MAX_STOPS)
                    .map { |child| { label: "Stop #{child[:short_id]}", command: "/children stop #{child[:short_id]}" } }
    ctx.card(id: CARD_ID, title: title, body: body, actions: [{ label: "Refresh", command: refresh }, *stops])
    nil
  end

  # - `ab12cd34` · running · fix/flaky · "fix the flaky spec…"
  # - `9a8b7c6d` · done · feat/x · reported · "All 12 specs pass…"
  # - `77aa66bb` · waiting (approval) · open it: chi --attach 77aa66bb
  def line(child)
    parts = ["`#{child[:short_id]}`", child[:waiting] ? "waiting (#{child[:waiting]})" : child[:state]]
    parts << child[:branch] if child[:branch]
    parts << "fork" unless child[:delegate]
    parts << "archived" if child[:archived]
    if child[:waiting]
      parts << "open it: chi --attach #{child[:short_id]}"
    elsif child[:last_reply]
      parts << (child[:reported] ? "reported" : "not reported yet")
      parts << quote(child[:last_reply])
    elsif !child[:title].to_s.strip.empty?
      parts << quote(child[:title])
    end
    "- #{parts.join(" · ")}"
  end

  def stop(id, ctx)
    stopped = ctx.sessions.stop(id)
    show(ctx, all: false, note: "stopped #{stopped[0, 8]}")
  rescue Samagotchi::Plugin::Sessions::Error => e
    "/children stop: #{e.message}"
  end

  def coordinate(goal, ctx)
    return COORDINATE_USAGE if goal.empty?

    verb, rest = goal.split(/\s+/, 2)
    # "resume" and at most a name; "resume the old work" is a goal.
    return resume(rest.to_s.strip, ctx) if verb == "resume" && !rest.to_s.strip.match?(/\s/)

    ask(ctx, "Read the skill_coordinator memory and follow it for this goal:\n\n#{goal}",
        "asked chi to coordinate it; a running turn gets it at its next step")
  end

  # /coordinate resume [name]
  def resume(name, ctx)
    open = open_handoffs(ctx)
    if name.empty?
      return "no open coordinator handoff (handoff_* memory) in this project" if open.empty?
      return resume_card(open, ctx) if open.size > 1

      name = open.first[:name]
    end
    name = "handoff_#{name}" unless name.start_with?("handoff_")
    unless open.any? { |handoff| handoff[:name] == name }
      return "/coordinate resume: no open handoff #{name} in this project (#{open.empty? ? "none is open" : "open: #{open.map { |h| h[:name] }.join(", ")}"})"
    end

    ask(ctx, "Read the skill_coordinator memory and resume the coordinator handoff #{name}: follow the skill's " \
             "Resume (step 0) before anything else.",
        "asked chi to resume #{name}; a running turn gets it at its next step")
  end

  def resume_card(open, ctx)
    body = open.map { |handoff| "- #{handoff[:name]}#{" — #{handoff[:description]}" unless handoff[:description].empty?}" }
    actions = open.first(MAX_RESUMES).map do |handoff|
      { label: "Resume #{handoff[:name].delete_prefix("handoff_")}", command: "/coordinate resume #{handoff[:name]}" }
    end
    ctx.card(id: RESUME_CARD_ID, title: "open handoffs (#{open.size})", body: body.join("\n"), actions: actions)
    nil
  end

  # The project's handoff_* memories whose index line isn't DONE, in index
  # order: [{name:, description:}]. A line without its file is left out.
  def open_handoffs(ctx)
    dir = Samagotchi::MemoryPaths.scope_dir("project", cwd: ctx.cwd)
    index = File.join(dir.to_s, "index.md")
    return [] unless File.file?(index)

    File.read(index, encoding: "UTF-8").each_line.filter_map do |line|
      match = line.chomp.match(HANDOFF_LINE) or next
      description = match[2].split(" — ", 2)[1].to_s.strip
      next if description.match?(/\ADONE\b/i)
      next unless File.file?(File.join(dir, "#{match[1]}.md"))

      { name: match[1], description: description }
    end
  rescue SystemCallError
    []
  end

  def ask(ctx, request, done)
    begin
      ctx.sessions.send(ctx.session_id, request)
    rescue Samagotchi::Plugin::Sessions::Error => e
      return "/coordinate: #{e.message}. Send this yourself:\n\n#{request}"
    end
    done
  end

  def quote(text)
    line = text.to_s.gsub(/\s+/, " ").strip
    line = "#{line[0, TEXT_CHARS - 1]}…" if line.length > TEXT_CHARS
    "\"#{line}\""
  end
end
