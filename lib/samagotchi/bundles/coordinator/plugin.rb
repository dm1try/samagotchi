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
# A child is asked before it changes anything outside its worktree by chi
# itself (the core child-boundary guardrail), in every mode: nothing to set up.
class Plugin
  CARD_ID = "children"
  # A card takes 6 actions: Refresh and up to 5 Stops.
  MAX_STOPS = 5
  STOPPABLE = %w[running waiting].freeze
  TEXT_CHARS = 80
  USAGE = "usage: /children [all] | /children stop <id>"
  COORDINATE_USAGE = "usage: /coordinate <goal> — chi splits it into tasks, one child session and worktree each"

  def initialize(_settings = {}); end

  def register(chi)
    chi.command "/children", "this session's child sessions: state, branch, last reply; all, stop <id>",
                anytime: true do |args, ctx|
      children_command(args.to_s.strip, ctx)
    end
    chi.command "/coordinate", "run work in parallel: chi splits <goal> into tasks, each in a child session and worktree",
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

    request = "Read the skill_coordinator memory and follow it for this goal:\n\n#{goal}"
    begin
      ctx.sessions.send(ctx.session_id, request)
    rescue Samagotchi::Plugin::Sessions::Error => e
      return "/coordinate: #{e.message}. Send this yourself:\n\n#{request}"
    end
    "asked chi to coordinate it; a running turn gets it at its next step"
  end

  def quote(text)
    line = text.to_s.gsub(/\s+/, " ").strip
    line = "#{line[0, TEXT_CHARS - 1]}…" if line.length > TEXT_CHARS
    "\"#{line}\""
  end
end
