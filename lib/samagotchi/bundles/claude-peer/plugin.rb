# frozen_string_literal: true

require "io/wait"
require "json"
require "socket"
require "samagotchi/plugin/peer"

# claude-peer (docs/plugins.md, The claude-peer bundle): a live link between
# this chi session and a Claude Code session the user works with. Claude
# pairs (its chi-peer skill, scripts/pair): it attaches the `claude-inbox`
# context, whose hint is its per-session inbox socket
# (CLAUDE_CODE_MESSAGING_SOCKET), and `claude-outbox`, where its answers
# come back as pushes that wake chi.
#
# The claude_send tool sends a part of the work (a plan step, a diff, a
# finding) to that socket as one JSON line, the format Claude Code's inbox
# takes: {"type":"user","message":{"role":"user","content":"…"}}. It is
# undocumented (found in Claude Code 2.1.296), and a line it can't parse is
# dropped silently, so the format lives in one place: #line. The message
# starts with a header, `chi <id> · <kind> · <title>`; a short part follows
# inline, a long one goes to a file under the bundle's data dir
# (sessions/<id>/, removed with the session) and the message names it
# (`payload: <path>`). No auth line: optional on macOS and Linux; native
# Windows, which needs one, isn't supported.
#
# The tool is declared whether or not Claude is paired, so pairing never
# changes the tools (no prompt rebuild). Without a paired Claude it fails
# with how to pair.
#
# /claude (anytime: it only reads files, writes one and posts to a socket)
# lets the user send without the model: `/claude` alone is a status card
# (paired or not, the socket and whether it is there, the last send, the
# last claude-outbox answer); `/claude validate|context <text>` sends the
# text as it is, titled by its first line; `/claude last` sends the model's
# last completed answer as context (mid-turn, a worker's ctx.messages holds
# the running turn's partial text, so the before_turn and after_turn hooks
# keep what was completed); `/claude install-skill` shows a card with
# Claude's chi-peer skill's target and an Install action (`--yes`), the card
# being the user's consent: the copy happens in-process, where no guardrail
# sees it. The skill is scripts/chi-peer-SKILL.md beside this file, with the
# installed scripts/pair path and the payload folder written in.
#
# In the web, selecting text offers "Confirm with Claude" (chi.annotation;
# skipped on a chi without it, 0.62–0.65): it fills the composer with
# `/claude validate` and the quote, for the user to add what to confirm.
# Such a text is titled by its first quoted line, not the quote's
# `From your thinking:` label.
#
# What the peer bundles share (the tool, the command, the cards, payloads)
# is Samagotchi::Plugin::Peer; this class has Claude's strings and the
# socket transport.
class Plugin < Samagotchi::Plugin::Peer
  INBOX = "claude-inbox"
  OUTBOX = "claude-outbox"
  BUNDLE = "claude-peer"
  NAME = "Claude"
  APP = "Claude Code"
  COMMAND = "/claude"
  TOOL = "claude_send"
  # The socket must take the line within this long.
  WRITE_SECONDS = 5
  # The Claude Code version the wire format was checked on.
  CHECKED_ON = "Claude Code 2.1.296"
  STATUS_CARD = "claude"
  SKILL_CARD = "claude-skill"
  USAGE = "usage: /claude — whether a Claude Code session is paired; /claude validate <text> | context <text> — send " \
          "the text to it; /claude last — send the last answer as context; /claude install-skill — install Claude's " \
          "chi-peer skill, which pairs"
  # The shipped bundle keeps scripts/ beside plugin.rb; an installed one
  # has plugin/plugin.rb and scripts/ beside plugin/.
  SCRIPTS_DIRS = [File.join(__dir__, "scripts"), File.expand_path("../scripts", __dir__)].freeze

  TOOL_DESCRIPTION = "Send a part of this session's work (a plan step, a diff, a finding, your " \
                     "last answer) to the Claude Code session paired with it (the claude-inbox " \
                     "context), for Claude to validate, to take as context, or to answer a " \
                     "question about. Only when the user asks for it, or to reply to its answer " \
                     "in a peer turn. Needs a paired Claude Code session: without one it fails, " \
                     "and the user pairs from Claude. Claude's answer comes back later as the " \
                     "claude-outbox context (a validate's wakes you): don't wait or poll. Never " \
                     "send secrets or the whole conversation."
  TOOL_PARAMS = {
    kind: { type: "string", enum: KINDS, required: true,
            description: "validate: check this part and answer with a verdict; context: for Claude to know, no " \
                         "answer expected; question: answer the question in text" },
    title: { type: "string", required: true,
             description: "A short one-line title for the part; Claude's answer names it" },
    text: { type: "string", required: true,
            description: "The part itself and what to check or ask, as Claude should read it; name the files, " \
                         "functions or diff range to look at. A long text goes to a file Claude reads" }
  }.freeze

  # The one JSON line Claude Code's inbox socket takes.
  def line(content) = "#{JSON.generate(type: "user", message: { role: "user", content: content })}\n"

  private

  # The paired Claude's inbox socket: the claude-inbox context's hint.
  def check_hint!(hint)
    raise SendError, "claude-inbox's hint isn't a socket path (#{hint}): pair again from Claude" unless hint.start_with?("/")
  end

  def paired_lines(socket)
    there = File.socket?(socket) ? "there" : "**missing**: that Claude session ended or restarted, pair again"
    ["**paired** with a Claude Code session", "socket: `#{socket}` (#{there})"]
  end

  def transport_line
    "The inbox's format is undocumented: checked on #{CHECKED_ON}. A Claude that bypasses permissions holds peer " \
      "messages for approval."
  end

  def setup_paragraph(ctx)
    rule = "Read(#{tilde(ctx.data_dir)}/**)"
    "So Claude isn't asked before reading a long part's file, add `#{rule}` to Claude Code's permissions " \
      "(`permissions.allow` in its settings.json); chi doesn't change Claude's settings."
  end

  # Claude Code's config folder: CLAUDE_CONFIG_DIR, else ~/.claude.
  def peer_dir
    dir = ENV.fetch("CLAUDE_CONFIG_DIR", "").strip
    dir.empty? ? File.join(Dir.home, ".claude") : File.expand_path(dir)
  end

  def post(socket, text)
    UNIXSocket.open(socket) { |conn| write_all(conn, line(text)) }
  rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ENOTSOCK
    raise SendError, "that Claude session is gone (no inbox at #{socket}): pair again from Claude"
  rescue SystemCallError, IOError => e
    raise SendError, "couldn't send to Claude: #{e.message}"
  end

  def write_all(conn, data)
    data = data.b
    until data.empty?
      written = conn.write_nonblock(data, exception: false)
      if written == :wait_writable
        raise SendError, "Claude's inbox didn't take the message in #{WRITE_SECONDS} s" unless conn.wait_writable(WRITE_SECONDS)

        next
      end
      data = data.byteslice(written..)
    end
  end
end
