# frozen_string_literal: true

require "json"
require "open3"
require "samagotchi/plugin/peer"

# codex-peer (docs/plugins.md, The codex-peer bundle): a live link between
# this chi session and an OpenAI Codex CLI session the user works with, the
# claude-peer bundle with the transport swapped. Codex pairs (its chi-peer
# skill, scripts/pair): it attaches the `codex-inbox` context, whose hint is
# its thread id (CODEX_THREAD_ID), and `codex-outbox`, where its answers
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
# codex-outbox answer); `/codex validate|context <text>` sends the text as
# it is, titled by its first line; `/codex last` sends the model's last
# completed answer as context (mid-turn, a worker's ctx.messages holds the
# running turn's partial text, so the before_turn and after_turn hooks keep
# what was completed); `/codex install-skill` shows a card with Codex's
# chi-peer skill's target ($CODEX_HOME, else ~/.codex) and an Install
# action (`--yes`), the card being the user's consent: the copy happens
# in-process, where no guardrail sees it. The skill is
# scripts/chi-peer-SKILL.md beside this file, with the installed
# scripts/pair path, the payload folder and chi's context folder written
# in. The card shows the writable_roots line Codex's config.toml needs for
# pairing and replies (its default sandbox can't write chi's state); chi
# never edits Codex's config.
#
# In the web, selecting text offers "Confirm with Codex" (chi.annotation):
# it fills the composer with
# `/codex validate` and the quote, for the user to add what to confirm.
# Such a text is titled by its first quoted line, not the quote's
# `From your thinking:` label.
#
# What the peer bundles share (the tool, the command, the cards, payloads)
# is Samagotchi::Plugin::Peer; this class has Codex's strings and the
# codex queue transport.

class Plugin < Samagotchi::Plugin::Peer
  INBOX = "codex-inbox"
  OUTBOX = "codex-outbox"
  BUNDLE = "codex-peer"
  NAME = "Codex"
  APP = "Codex"
  COMMAND = "/codex"
  TOOL = "codex_send"
  # codex queue must be done within this long, or it is killed.
  QUEUE_SECONDS = 10
  # The Codex CLI version codex queue was checked on.
  CHECKED_ON = "Codex 0.162.1"
  THREAD_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  STATUS_CARD = "codex"
  SKILL_CARD = "codex-skill"
  USAGE = "usage: /codex — whether a Codex session is paired; /codex validate <text> | context <text> — send the " \
          "text to it; /codex last — send the last answer as context; /codex install-skill — install Codex's " \
          "chi-peer skill, which pairs"
  # The shipped bundle keeps scripts/ beside plugin.rb; an installed one
  # has plugin/plugin.rb and scripts/ beside plugin/.
  SCRIPTS_DIRS = [File.join(__dir__, "scripts"), File.expand_path("../scripts", __dir__)].freeze
  CONTEXT_PLACEHOLDER = "__CHI_PEER_CONTEXT__"

  TOOL_DESCRIPTION = "Send a part of this session's work (a plan step, a diff, a finding, your " \
                     "last answer) to the Codex CLI session paired with it (the codex-inbox " \
                     "context), for Codex to validate, to take as context, or to answer a " \
                     "question about. Only when the user asks for it, or to reply to its answer " \
                     "in a peer turn. Needs a paired Codex session: without one it fails, and the " \
                     "user pairs from Codex. Codex's answer comes back later as the codex-outbox " \
                     "context (a validate's wakes you): don't wait or poll. Never send secrets or " \
                     "the whole conversation."
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

  private

  # The paired Codex's thread id: the codex-inbox context's hint.
  def check_hint!(hint)
    raise SendError, "codex-inbox's hint isn't a Codex thread id (#{hint}): pair again from Codex" unless hint.match?(THREAD_ID)
  end

  # There is no cheap check that the thread is still there, and a closed
  # Codex session still takes sends (the app-server keeps them; codex queue
  # exits 0).
  def paired_lines(thread)
    ["**paired** with a Codex session", "thread: `#{thread}` (a closed Codex session still takes sends: they wait " \
                                        "for `codex resume` there, or pair again)"]
  end

  def transport_line = "Sent with `codex queue`: checked on #{CHECKED_ON}."

  def setup_paragraph(ctx)
    "Codex's default sandbox can't write chi's state, and pairing and replies do: add to " \
      "`#{File.join(peer_dir, "config.toml")}` (into its `[sandbox_workspace_write]` section if it has one), " \
      "then restart Codex:\n\n```toml\n#{roots_line(ctx)}\n```\n\nchi doesn't change Codex's settings."
  end

  def installed_line(short) = "Restart Codex if it is running, then say \"pair with chi #{short}\"."

  def skill_substitutions(ctx) = { CONTEXT_PLACEHOLDER => context_dir(ctx) }

  # Codex's config folder: CODEX_HOME, else ~/.codex.
  def peer_dir
    dir = ENV.fetch("CODEX_HOME", "").strip
    dir.empty? ? File.join(Dir.home, ".codex") : File.expand_path(dir)
  end

  # chi's context folder (<state>/samagotchi/context, where a push
  # writes), beside the bundle's data dir (<state>/samagotchi/plugins/<name>).
  # Absolute: config.toml doesn't expand ~.
  def context_dir(ctx) = File.expand_path("../../context", ctx.data_dir)

  def roots_line(ctx) = "[sandbox_workspace_write]\nwritable_roots = [#{JSON.generate(context_dir(ctx))}]"

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
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + QUEUE_SECONDS
    Open3.popen3(*command, pgroup: true) do |stdin, stdout, stderr, wait|
      stdin.close
      out, err = [stdout, stderr].map { |io| Thread.new { io.read }.tap { |t| t.report_on_exception = false } }
      threads = [wait, out, err]
      within_deadline = lambda do |thread|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        thread.join([remaining, 0].max)
      end
      unless threads.all?(&within_deadline)
        begin
          Process.kill("KILL", -wait.pid)
        rescue SystemCallError
          nil
        end
        # The group is gone, so the pipes end: let the readers finish
        # before popen3 closes them.
        cleanup_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        threads.each do |thread|
          remaining = cleanup_deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          thread.join([remaining, 0].max)
        end
        # The queue itself finished fine, and only a process it left held
        # the pipes: the message is likely queued, so don't say "try again"
        # (a retry would deliver it twice).
        if wait.join(0) && wait.value.success?
          raise SendError, "codex queue exited but left a process holding its output (stopped after " \
                           "#{QUEUE_SECONDS} s): the message may already be queued, check Codex before sending again"
        end
        raise SendError, "Codex didn't take the message in #{QUEUE_SECONDS} s (codex queue was stopped): try " \
                         "again, or pair again from Codex"
      end
      [out.value, err.value, wait.value]
    end
  end
end
