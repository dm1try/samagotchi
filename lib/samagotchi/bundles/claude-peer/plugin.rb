# frozen_string_literal: true

require "fileutils"
require "io/wait"
require "json"
require "open3"
require "socket"
require "tempfile"
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
#
# /claude (anytime: it only reads files, writes one and posts to a socket)
# lets the user send without the model: `/claude` alone is a status card
# (paired or not, the socket and whether it is there, the last send, the
# last claude-review answer); `/claude validate|context <text>` sends the
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
  STATUS_CARD = "claude"
  SKILL_CARD = "claude-skill"
  USAGE = "usage: /claude — whether a Claude Code session is paired; /claude validate <text> | context <text> — send " \
          "the text to it; /claude last — send the last answer as context; /claude install-skill — install Claude's " \
          "chi-peer skill, which pairs"
  # The shipped bundle keeps scripts/ beside plugin.rb; an installed one
  # has plugin/plugin.rb and scripts/ beside plugin/.
  SCRIPTS_DIRS = [File.join(__dir__, "scripts"), File.expand_path("../scripts", __dir__)].freeze
  SKILL_FILE = "chi-peer-SKILL.md"
  PAIR_PLACEHOLDER = "__CHI_PEER_PAIR__"
  PAYLOADS_PLACEHOLDER = "__CHI_PEER_PAYLOADS__"
  DIFF_LINES = 20
  # The label line a web quote starts with (annotations.js sourceLabel).
  QUOTE_LABEL = /\AFrom (?:your thinking|your earlier step|the .+ call|my earlier message):\z/

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
    # The running turn's history before it (nil between turns), and the
    # last completed answer this process saw.
    @before_turn = nil
    @last_answer = nil
  end

  def register(chi)
    chi.tool "claude_send", TOOL_DESCRIPTION, params: TOOL_PARAMS, label: "sent to Claude",
                                              preview: ->(args) { "#{args["kind"]}: #{args["title"]}" } do |args, ctx|
      sent = deliver(ctx, kind: args["kind"].to_s, title: args["title"].to_s, text: args["text"].to_s)
      "#{sent}. #{follow_up(args["kind"].to_s)}"
    rescue SendError => e
      "Error: #{e.message}"
    end
    chi.command "/claude", "the paired Claude Code session: status; validate|context <text>, last: send to it; " \
                           "install-skill: install Claude's chi-peer skill", anytime: true do |args, ctx|
      claude(args.to_s.strip, ctx)
    end
    # A chi without chi.annotation (0.62–0.65) loads the bundle without the pill.
    chi.annotation "Confirm with Claude", command: "/claude validate" if chi.respond_to?(:annotation)
    chi.on(:before_turn) do |event|
      @lock.synchronize { @before_turn = Array(event[:messages]) }
    end
    chi.on(:after_turn) do |event|
      answer = completed_answer(event[:messages]) if event[:status].to_s == "completed"
      @lock.synchronize do
        @before_turn = nil
        @last_answer = answer if answer
      end
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

  def claude(args, ctx)
    verb = args.split(/\s+/, 2).first
    # The rest as typed: a pasted selection keeps its lines.
    rest = args.sub(/\A\S+\s*/, "")
    case verb
    when nil then status(ctx)
    when "validate", "context" then rest.strip.empty? ? USAGE : send_text(ctx, verb, rest)
    when "last" then rest.empty? ? send_last(ctx) : USAGE
    when "install-skill" then install_skill(ctx, yes: rest == "--yes")
    else USAGE
    end
  end

  def send_text(ctx, kind, text)
    "#{deliver(ctx, kind: kind, title: text_title(text), text: text)}; Claude's answer comes as the " \
      "claude-review context"
  rescue SendError => e
    "/claude: #{e.message}"
  end

  # A typed text's title: its first line, past a web quote's label line
  # (`From your thinking:`) and the `> ` of a quoted line.
  def text_title(text)
    lines = text.strip.lines.map(&:strip).reject { |line| line.match?(QUOTE_LABEL) }
    lines.map { |line| line.sub(/\A>\s*/, "") }.find { |line| !line.empty? }.to_s
  end

  def send_last(ctx)
    answer, before = @lock.synchronize { [@last_answer, @before_turn] }
    answer ||= completed_answer(before || ctx.messages)
    return "/claude last: no completed answer to send yet (the last turn has none); /claude context <text> sends a text" unless answer

    deliver(ctx, kind: "context", title: "chi's last answer: #{answer.strip.lines.first}", text: answer)
  rescue SendError => e
    "/claude: #{e.message}"
  end

  # The answer a completed turn left: the history's last message when it
  # is the model's (a cancelled, failed or empty turn ends in a turn note),
  # after any notes that joined between turns; its thinking left out.
  def completed_answer(messages)
    last = Array(messages).reverse.find { |message| !(role(message) == "system" && kind(message) != "turn_note") }
    return nil unless last && role(last) == "model" && !field(last, :interrupted) && !field(last, :tool_calls)

    text = field(last, :content)
    text = text.filter_map { |part| field(part, :text) if part.is_a?(Hash) }.join("\n") if text.is_a?(Array)
    text = text.to_s.gsub(%r{<think>.*?</think>}m, "").strip
    text.empty? ? nil : text
  end

  # The session's attached sources; none when they can't be read (chi 0.62
  # raises for a new session not saved yet; a corrupt session file).
  def sources(ctx)
    ctx.context.list
  rescue ArgumentError, SystemCallError
    []
  end

  def role(message) = field(message, :role).to_s
  def kind(message) = field(message, :kind).to_s
  def field(hash, key) = hash.is_a?(Hash) ? hash[key] || hash[key.to_s] : nil

  # The status card; nil, so the command adds no text.
  def status(ctx)
    id = ctx.session_id
    sources = id ? sources(ctx) : []
    inbox, review = [INBOX, REVIEW].map { |name| sources.find { |source| source[:name] == name } }
    socket = inbox && inbox[:hint].to_s.strip
    lines = if socket.nil? || socket.empty?
              ["**not paired.** In Claude Code, install the chi-peer skill (Install skill below), then tell Claude " \
               "\"pair with chi #{id.to_s[0, 8]}\"."]
            else
              there = File.socket?(socket) ? "there" : "**missing**: that Claude session ended or restarted, pair again"
              ["**paired** with a Claude Code session", "socket: `#{socket}` (#{there})"]
            end
    lines << "last send: #{last_send_line(ctx, id)}" if id && last_send(ctx, id)
    lines << "last answer (claude-review): #{review_line(review)}" if review
    lines << "The inbox's format is undocumented: checked on #{CHECKED_ON}. A Claude that bypasses permissions " \
             "holds peer messages for approval."
    ctx.card(id: STATUS_CARD, title: "claude-peer: #{lines.first.start_with?("**paired") ? "paired" : "not paired"}",
             body: lines.join("\n\n"), actions: [{ label: "Refresh", command: "/claude" },
                                                 { label: "Install skill", command: "/claude install-skill" }])
    nil
  end

  def last_send(ctx, id)
    path = File.join(ctx.data_dir, "sessions", id, LAST_SEND)
    File.file?(path) ? JSON.parse(File.read(path)) : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def last_send_line(ctx, id)
    sent = last_send(ctx, id)
    where = sent["payload"] ? "in `#{sent["payload"]}`" : "inline"
    "#{ago(sent["at"])} · #{sent["kind"]} · #{sent["title"]} (#{sent["chars"]} chars, #{where})"
  end

  # The summary needs chi 0.63.0 (ctx.context.list's summary:).
  def review_line(review)
    return "none yet" unless review[:fetched_at]

    [review[:summary], ago(review[:fetched_at])].compact.join(" · ")
  end

  def ago(stamp)
    seconds = (Time.now - Time.iso8601(stamp.to_s)).to_i
    if seconds < 60 then "just now"
    elsif seconds < 3600 then "#{seconds / 60} min ago"
    elsif seconds < 86_400 then "#{seconds / 3600} h ago"
    else Time.iso8601(stamp).localtime.strftime("%Y-%m-%d %H:%M")
    end
  rescue ArgumentError
    stamp.to_s
  end

  # /claude install-skill [--yes]
  def install_skill(ctx, yes:)
    source = SCRIPTS_DIRS.map { |dir| File.join(dir, SKILL_FILE) }.find { |path| File.file?(path) }
    return "/claude install-skill: this bundle has no scripts/#{SKILL_FILE}; reinstall it (chi bundle install claude-peer --force)" unless source

    text = File.read(source).gsub(PAIR_PLACEHOLDER, File.join(File.dirname(source), "pair"))
                            .gsub(PAYLOADS_PLACEHOLDER, tilde(ctx.data_dir))
    target = File.join(claude_dir, "skills", "chi-peer", "SKILL.md")
    yes ? write_skill(ctx, target, text) : skill_card(ctx, target, text)
  end

  def skill_card(ctx, target, text)
    current = File.file?(target) ? File.read(target) : nil
    state = if current.nil? then "Not installed yet."
            elsif current == text then "Installed and up to date."
            else "Installed, and different from this bundle's (Replace overwrites it):\n\n```diff\n#{diff(target, text)}\n```"
            end
    rule = "Read(#{tilde(ctx.data_dir)}/**)"
    body = ["Claude Code's side: it pairs (`pair with chi <id>`), answers validates and replies into chi.",
            "target: `#{target}`", state,
            "So Claude isn't asked before reading a long part's file, add `#{rule}` to Claude Code's permissions " \
            "(`permissions.allow` in its settings.json); chi doesn't change Claude's settings."]
    actions = if current == text
                []
              else
                [{ label: current ? "Replace" : "Install", command: "/claude install-skill --yes" }]
              end
    ctx.card(id: SKILL_CARD, title: "Claude's chi-peer skill", body: body.join("\n\n"), actions: actions)
    nil
  end

  def write_skill(ctx, target, text)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, text)
    ctx.card(id: SKILL_CARD, title: "Claude's chi-peer skill",
             body: "Installed `#{target}`. In Claude Code, say \"pair with chi #{ctx.session_id.to_s[0, 8]}\".")
    nil
  rescue SystemCallError => e
    "/claude install-skill: couldn't write #{target}: #{e.message}"
  end

  # Claude Code's config folder: CLAUDE_CONFIG_DIR, else ~/.claude.
  def claude_dir
    dir = ENV.fetch("CLAUDE_CONFIG_DIR", "").strip
    dir.empty? ? File.join(Dir.home, ".claude") : File.expand_path(dir)
  end

  # The first lines of `diff -u installed new`.
  def diff(target, text)
    Tempfile.create(["chi-peer", ".md"]) do |file|
      file.write(text)
      file.flush
      out, = Open3.capture2("diff", "-u", "--label", "installed", "--label", "this bundle's", target, file.path)
      lines = out.lines
      lines = lines.first(DIFF_LINES) + ["… #{lines.size - DIFF_LINES} more lines\n"] if lines.size > DIFF_LINES
      lines.join.chomp
    end
  rescue SystemCallError
    "(diff isn't there to show how)"
  end

  def tilde(path)
    home = Dir.home
    path.start_with?("#{home}/") ? "~#{path.delete_prefix(home)}" : path
  end

  def follow_up(kind)
    case kind
    when "context" then "Claude takes it in; it answers only if something in it is wrong."
    else "Claude's answer comes as an update of the claude-review context; don't wait or poll."
    end
  end

  # The paired Claude's inbox socket: the claude-inbox context's hint.
  def socket_path(ctx)
    inbox = sources(ctx).find { |source| source[:name] == INBOX }
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
