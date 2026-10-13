# frozen_string_literal: true

require "fileutils"
require "io/wait"
require "json"
require "socket"
require "time"

# claude-peer (docs/plugins.md, The claude-peer bundle): a live link between
# this chi session and a Claude Code session the user works with. Claude
# pairs (its chi-peer skill, scripts/pair): it attaches the `claude-inbox`
# context, whose hint is its per-session inbox socket
# (CLAUDE_CODE_MESSAGING_SOCKET), and `claude-review`, where its answers
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
class Plugin
  INBOX = "claude-inbox"
  REVIEW = "claude-review"
  KINDS = %w[validate context question].freeze
  # A part up to this long goes inline: Claude reads it with no file access.
  INLINE_CHARS = 4_000
  # A part longer than this is refused (Claude takes ~1M; a send is a part,
  # not a session).
  MAX_CHARS = 200_000
  TITLE_CHARS = 80
  SLUG_CHARS = 40
  # The socket must take the line within this long.
  WRITE_SECONDS = 5
  # The Claude Code version the wire format was checked on.
  CHECKED_ON = "Claude Code 2.1.296"
  LAST_SEND = "last-send.json"

  TOOL_DESCRIPTION = "Send a part of this session's work (a plan step, a diff, a finding, your last answer) to the " \
                     "Claude Code session paired with it (the claude-inbox context), for Claude to validate, to take " \
                     "as context, or to answer a question about. Only when the user asks for it. Needs a paired " \
                     "Claude Code session: without one it fails, and the user pairs from Claude. Claude's answer " \
                     "comes back later as the claude-review context (a validate's wakes you): don't wait or poll. " \
                     "Never send secrets or the whole conversation."
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

  # A send that didn't happen; the message says why, for the model or the user.
  class SendError < StandardError; end

  def initialize(_settings = {})
    @lock = Mutex.new
  end

  def register(chi)
    chi.tool "claude_send", TOOL_DESCRIPTION, params: TOOL_PARAMS, label: "sent to Claude",
                                              preview: ->(args) { "#{args["kind"]}: #{args["title"]}" } do |args, ctx|
      sent = deliver(ctx, kind: args["kind"].to_s, title: args["title"].to_s, text: args["text"].to_s)
      "#{sent}. #{follow_up(args["kind"].to_s)}"
    rescue SendError => e
      "Error: #{e.message}"
    end
  end

  # Sends +text+ to the paired Claude: the header, then the text inline or
  # a payload file's path. Records it as the last send.
  # @return [String] what was sent ("sent to Claude: validate · title, inline")
  # @raise [SendError]
  def deliver(ctx, kind:, title:, text:)
    raise SendError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
    raise SendError, "nothing to send: the text is empty" if text.strip.empty?
    if text.length > MAX_CHARS
      raise SendError, "the text is #{text.length} chars, over #{MAX_CHARS}: send a part, not a session"
    end

    id = ctx.session_id or raise SendError, "this session has no id yet: send after its first turn"
    socket = socket_path(ctx)
    title = one_line(title.strip.empty? ? text.strip.lines.first : title)
    body, where = if text.length <= INLINE_CHARS
                    [text, "inline"]
                  else
                    path = write_payload(ctx, id, title, text)
                    ["payload: #{path} (#{text.lines.size} lines, #{text.length} chars)", path]
                  end
    post(socket, line("chi #{id[0, 8]} · #{kind} · #{title}\n#{body}"))
    record(ctx, id, kind: kind, title: title, chars: text.length, payload: where == "inline" ? nil : where)
    "sent to Claude: #{kind} · #{title}#{" (the text in #{where})" unless where == "inline"}"
  end

  # The one JSON line Claude Code's inbox socket takes.
  def line(content) = "#{JSON.generate(type: "user", message: { role: "user", content: content })}\n"

  private

  def follow_up(kind)
    case kind
    when "context" then "Claude takes it in; it answers only if something in it is wrong."
    else "Claude's answer comes as an update of the claude-review context; don't wait or poll."
    end
  end

  # The paired Claude's inbox socket: the claude-inbox context's hint.
  def socket_path(ctx)
    inbox = ctx.context.list.find { |source| source[:name] == INBOX }
    hint = inbox && inbox[:hint].to_s.strip
    if hint.nil? || hint.empty?
      raise SendError, "no claude-inbox: pair from Claude (install its skill with /claude install-skill, then " \
                       "tell Claude \"pair with chi #{ctx.session_id.to_s[0, 8]}\")"
    end
    raise SendError, "claude-inbox's hint isn't a socket path (#{hint}): pair again from Claude" unless hint.start_with?("/")

    hint
  end

  def post(socket, data)
    UNIXSocket.open(socket) { |conn| write_all(conn, data) }
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

  # sessions/<id>/<HHMMSS>-<slug>.md under the bundle's data dir, readable
  # by its owner only.
  def write_payload(ctx, id, title, text)
    dir = session_dir(ctx, id)
    base = "#{Time.now.strftime("%H%M%S")}-#{slug(title)}"
    path = File.join(dir, "#{base}.md")
    n = 1
    path = File.join(dir, "#{base}-#{n += 1}.md") while File.exist?(path)
    File.open(path, "w", 0o600) { |file| file.write(text) }
    path
  rescue SystemCallError => e
    raise SendError, "couldn't write the payload file: #{e.message}"
  end

  def session_dir(ctx, id)
    File.join(ctx.data_dir, "sessions", id).tap { |dir| FileUtils.mkdir_p(dir) }
  end

  def record(ctx, id, **send)
    entry = { at: Time.now.utc.iso8601, **send }
    @lock.synchronize { File.write(File.join(session_dir(ctx, id), LAST_SEND), JSON.generate(entry)) }
  rescue SystemCallError => e
    ctx.log.info(:last_send_not_saved, error: e.message)
  end

  def slug(title)
    slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, SLUG_CHARS].delete_suffix("-")
    slug.empty? ? "part" : slug
  end

  def one_line(text)
    line = text.to_s.gsub(/\s+/, " ").strip
    line.length > TITLE_CHARS ? "#{line[0, TITLE_CHARS - 1]}…" : line
  end
end
