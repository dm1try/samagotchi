# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "time"

# codex-peer (docs/plugins.md, The codex-peer bundle): a live link between
# this chi session and an OpenAI Codex CLI session the user works with, the
# claude-peer bundle with the transport swapped. Codex pairs (its chi-peer
# skill, scripts/pair): it attaches the `codex-inbox` context, whose hint is
# its thread id (CODEX_THREAD_ID), and `codex-review`, where its answers
# come back as pushes that wake chi.
#
# The codex_send tool sends a part of the work (a plan step, a diff, a
# finding) with `codex queue --thread <uuid> --message <text>`, which wakes
# an idle Codex TUI: the text runs there as a new user turn (checked on
# Codex 0.162.1). Plain text, no wire format. The message starts with a
# header, `chi <id> · <kind> · <title>`; a short part follows inline, a
# long one goes to a file under the bundle's data dir (sessions/<id>/,
# removed with the session) and the message names it (`payload: <path>`).
# `codex` is CODEX, else codex on the PATH; a queue that takes over
# QUEUE_SECONDS is killed (its process group), so a send never hangs.
#
# The tool is declared whether or not Codex is paired, so pairing never
# changes the tools (no prompt rebuild). Without a paired Codex it fails
# with how to pair.
#
# /codex (anytime: it reads files, writes one and runs `codex queue`, up to
# QUEUE_SECONDS) lets the user send without the model: `/codex` alone is a
# status card (paired or not, the thread, the last send, the last
# codex-review answer); `/codex validate|context <text>` sends the text as
# it is, titled by its first line; `/codex last` sends the model's last
# completed answer as context (mid-turn, a worker's ctx.messages holds the
# running turn's partial text, so the before_turn and after_turn hooks keep
# what was completed).
class Plugin
  INBOX = "codex-inbox"
  REVIEW = "codex-review"
  KINDS = %w[validate context question].freeze
  # A part up to this long goes inline (and keeps codex queue's argv small).
  INLINE_CHARS = 4_000
  # A part longer than this is refused (a send is a part, not a session).
  MAX_CHARS = 200_000
  TITLE_CHARS = 80
  SLUG_CHARS = 40
  # codex queue must be done within this long, or it is killed.
  QUEUE_SECONDS = 10
  # The Codex CLI version codex queue was checked on.
  CHECKED_ON = "Codex 0.162.1"
  THREAD_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  LAST_SEND = "last-send.json"
  STATUS_CARD = "codex"
  USAGE = "usage: /codex — whether a Codex session is paired; /codex validate <text> | context <text> — send the " \
          "text to it; /codex last — send the last answer as context"

  TOOL_DESCRIPTION = "Send a part of this session's work (a plan step, a diff, a finding, your last answer) to the " \
                     "Codex CLI session paired with it (the codex-inbox context), for Codex to validate, to take " \
                     "as context, or to answer a question about. Only when the user asks for it. Needs a paired " \
                     "Codex session: without one it fails, and the user pairs from Codex. Codex's answer comes " \
                     "back later as the codex-review context (a validate's wakes you): don't wait or poll. Never " \
                     "send secrets or the whole conversation."
  TOOL_PARAMS = {
    kind: { type: "string", enum: KINDS, required: true,
            description: "validate: check this part and answer with a verdict; context: for Codex to know, no " \
                         "answer expected; question: answer the question in text" },
    title: { type: "string", required: true,
             description: "A short one-line title for the part; Codex's answer names it" },
    text: { type: "string", required: true,
            description: "The part itself and what to check or ask, as Codex should read it; name the files, " \
                         "functions or diff range to look at. A long text goes to a file Codex reads" }
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
    chi.tool "codex_send", TOOL_DESCRIPTION, params: TOOL_PARAMS, label: "sent to Codex",
                                             preview: ->(args) { "#{args["kind"]}: #{args["title"]}" } do |args, ctx|
      sent = deliver(ctx, kind: args["kind"].to_s, title: args["title"].to_s, text: args["text"].to_s)
      "#{sent}. #{follow_up(args["kind"].to_s)}"
    rescue SendError => e
      "Error: #{e.message}"
    end
    chi.command "/codex", "the paired Codex session: status; validate|context <text>, last: send to it",
                anytime: true do |args, ctx|
      codex(args.to_s.strip, ctx)
    end
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

  # Sends +text+ to the paired Codex: the header, then the text inline or
  # a payload file's path. Records it as the last send.
  # @return [String] what was sent ("sent to Codex: validate · title")
  # @raise [SendError]
  def deliver(ctx, kind:, title:, text:)
    raise SendError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
    raise SendError, "nothing to send: the text is empty" if text.strip.empty?
    if text.length > MAX_CHARS
      raise SendError, "the text is #{text.length} chars, over #{MAX_CHARS}: send a part, not a session"
    end

    id = ctx.session_id or raise SendError, "this session has no id yet: send after its first turn"
    thread = thread_id(ctx)
    title = one_line(title.strip.empty? ? text.strip.lines.first : title)
    body, where = if text.length <= INLINE_CHARS
                    [text, "inline"]
                  else
                    path = write_payload(ctx, id, title, text)
                    ["payload: #{path} (#{text.lines.size} lines, #{text.length} chars)", path]
                  end
    post(thread, "chi #{id[0, 8]} · #{kind} · #{title}\n#{body}")
    record(ctx, id, kind: kind, title: title, chars: text.length, payload: where == "inline" ? nil : where)
    "sent to Codex: #{kind} · #{title}#{" (the text in #{where})" unless where == "inline"}"
  end

  private

  def codex(args, ctx)
    verb = args.split(/\s+/, 2).first
    # The rest as typed: a pasted selection keeps its lines.
    rest = args.sub(/\A\S+\s*/, "")
    case verb
    when nil then status(ctx)
    when "validate", "context" then rest.strip.empty? ? USAGE : send_text(ctx, verb, rest)
    when "last" then rest.empty? ? send_last(ctx) : USAGE
    else USAGE
    end
  end

  def send_text(ctx, kind, text)
    "#{deliver(ctx, kind: kind, title: text.strip.lines.first.to_s, text: text)}; Codex's answer comes as the " \
      "codex-review context"
  rescue SendError => e
    "/codex: #{e.message}"
  end

  def send_last(ctx)
    answer, before = @lock.synchronize { [@last_answer, @before_turn] }
    answer ||= completed_answer(before || ctx.messages)
    return "/codex last: no completed answer to send yet (the last turn has none); /codex context <text> sends a text" unless answer

    deliver(ctx, kind: "context", title: "chi's last answer: #{answer.strip.lines.first}", text: answer)
  rescue SendError => e
    "/codex: #{e.message}"
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

  # The session's attached sources; none when they can't be read (a new
  # session not saved yet; a corrupt session file).
  def sources(ctx)
    ctx.context.list
  rescue ArgumentError, SystemCallError
    []
  end

  def role(message) = field(message, :role).to_s
  def kind(message) = field(message, :kind).to_s
  def field(hash, key) = hash.is_a?(Hash) ? hash[key] || hash[key.to_s] : nil

  # The status card; nil, so the command adds no text. There is no cheap
  # check that the thread is still there, and a closed Codex session still
  # takes sends (the app-server keeps them; codex queue exits 0).
  def status(ctx)
    id = ctx.session_id
    sources = id ? sources(ctx) : []
    inbox, review = [INBOX, REVIEW].map { |name| sources.find { |source| source[:name] == name } }
    thread = inbox && inbox[:hint].to_s.strip
    paired = !(thread.nil? || thread.empty?)
    lines = if paired
              ["**paired** with a Codex session", "thread: `#{thread}` (a closed Codex session still takes sends: they wait " \
                                                                 "for `codex resume` there, or pair again)"]
            else
              ["**not paired.** In Codex, install the chi-peer skill, then tell Codex \"pair with chi " \
               "#{id.to_s[0, 8]}\"."]
            end
    lines << "last send: #{last_send_line(ctx, id)}" if id && last_send(ctx, id)
    lines << "last answer (codex-review): #{review_line(review)}" if review
    lines << "Sent with `codex queue`: checked on #{CHECKED_ON}."
    ctx.card(id: STATUS_CARD, title: "codex-peer: #{paired ? "paired" : "not paired"}",
             body: lines.join("\n\n"), actions: [{ label: "Refresh", command: "/codex" }])
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

  def follow_up(kind)
    case kind
    when "context" then "Codex takes it in; it answers only if something in it is wrong."
    else "Codex's answer comes as an update of the codex-review context; don't wait or poll."
    end
  end

  # The paired Codex's thread id: the codex-inbox context's hint.
  def thread_id(ctx)
    inbox = sources(ctx).find { |source| source[:name] == INBOX }
    hint = inbox && inbox[:hint].to_s.strip
    if hint.nil? || hint.empty?
      raise SendError, "no codex-inbox: pair from Codex (install its skill with /codex install-skill, then " \
                       "tell Codex \"pair with chi #{ctx.session_id.to_s[0, 8]}\")"
    end
    raise SendError, "codex-inbox's hint isn't a Codex thread id (#{hint}): pair again from Codex" unless hint.match?(THREAD_ID)

    hint
  end

  def codex_command
    command = ENV.fetch("CODEX", "").strip
    command.empty? ? "codex" : command
  end

  # Runs `codex queue --thread <thread> --message <text>` (an argv, never a
  # shell line), killing its process group after QUEUE_SECONDS.
  def post(thread, text)
    command = codex_command
    _out, err, status = run(command, "queue", "--thread", thread, "--message", text)
    return if status.success?

    first = err.lines.map(&:strip).find { |line| !line.empty? }.to_s
    case first
    when /ephemeral/i
      raise SendError, "that Codex session is ephemeral and can't take queued messages: pair from an interactive " \
                       "Codex session"
    # Codex 0.162.1: "… failed to read thread: invalid thread-store request:
    # no rollout found for thread id <uuid> (code -32603)". A closed session
    # isn't this: its queue still succeeds.
    when /no rollout found|not found|unknown thread|no such thread|does not exist|no thread/i
      raise SendError, "that Codex session is gone (codex queue: #{first}): pair again from Codex"
    else
      raise SendError, "codex queue failed (exit #{status.exitstatus}): #{first.empty? ? "no error text" : first}"
    end
  rescue Errno::ENOENT, Errno::EACCES, Errno::ENOEXEC
    where = command == "codex" ? "no codex on the PATH" : "no Codex CLI at #{command}"
    raise SendError, "#{where}: install Codex CLI, or set CODEX= to its path where chi runs (a worker started by " \
                     "chi web or launchd may have another PATH)"
  end

  # [stdout, stderr, status]; both pipes read on threads, so a full one
  # can't block the command.
  def run(*command)
    Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      out, err = [stdout, stderr].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
      unless wait.join(QUEUE_SECONDS)
        begin
          Process.kill("KILL", -wait.pid)
        rescue SystemCallError
          nil
        end
        # The group is gone, so the pipes end: let the readers finish
        # before popen3 closes them.
        [wait, out, err].each { |t| t.join(1) }
        raise SendError, "Codex didn't take the message in #{QUEUE_SECONDS} s (codex queue was stopped): try " \
                         "again, or pair again from Codex"
      end
      [out.value, err.value, wait.value]
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
