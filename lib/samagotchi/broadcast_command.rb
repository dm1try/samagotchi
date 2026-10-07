# frozen_string_literal: true

require_relative "config"
require_relative "session"
require_relative "session_inbox"
require_relative "note_delivery"
require_relative "broadcast/recipients"
require_relative "broadcast/scope_card"
require_relative "broadcast/tags"
require_relative "broadcast/triage"
require_relative "broadcast/triage_model"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi broadcast`: share a note with every session it may concern,
  # without picking them. Each recipient (Broadcast::Recipients) that shares
  # a tag with the note (Broadcast::Tags) gets it as a context note from
  # "broadcast", and a triage model judges the rest (Broadcast::Triage);
  # --all gives it to every recipient. The rest are listed as skipped, with
  # why. For the user only: refused inside a chi session.
  class BroadcastCommand
    include CLI::Command

    SOURCE = "broadcast"
    # Bytes kept free under SessionInbox's 16 KiB for the line each note
    # ends with (#body).
    BODY_ROOM = 512
    # The longest "because" #body quotes (a link tag can be long).
    BECAUSE_CHARS = 200
    # The env every execute/task call exports (Tools::Builtins): set, the
    # command runs inside a chi session, i.e. an agent runs it.
    PARENT_ENV = "SAMAGOTCHI_PARENT_SESSION"

    USAGE = <<~TEXT
      Usage: chi broadcast [-m TEXT] [--all] [--dry-run]
        Shares TEXT (or stdin) with the sessions it may concern, as a context
        note from "broadcast": background the model sees on its next turn,
        not a prompt. It starts no turn.
        Recipients: your own sessions (not delegate children, not scratch
        ones) that a worker or a chi REPL runs now, or that ended a turn in
        the last broadcast.active_hours (8). One gets the note when it shares
        a tag with it: a ticket id (PAY-123) in its branch or your prompts
        there, a pull request (PR #42, its URL) attached to it, a link in
        your prompts there or its attached context. A triage model
        (broadcast.triage_model, else the recap's, else default.model) reads
        the note and each other session's scope card and says whether it
        concerns it; one it can't judge in broadcast.triage_deadline (20 s)
        gets it unchecked. A first line naming one project keeps the note to
        that project's sessions.
        -m TEXT    the note; without it, stdin is read
        --all      every recipient, no tags or triage
        --dry-run  show each recipient's scope card, tags and verdict; deliver nothing
        For you, not for an agent: refused inside a chi session.
        One session or a few by id: chi note. See docs/broadcast.md.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS, args: false) do |f|
      f.switch "--all"
      f.switch "--dry-run"
      f.value "-m", "--message", key: :text
    end

    # One recipient and its Broadcast::Triage::Verdict.
    Decision = Data.define(:recipient, :verdict) do
      def deliver? = verdict.relevant
    end

    # @param argv [Array<String>] the arguments after "broadcast"
    # @param active_hours [Numeric, nil] broadcast.active_hours (config)
    # @param ticket_pattern [String, nil] broadcast.ticket_pattern (config)
    # @param triage [#call, nil] (CancellationController) → a triage
    #   backend (#judge(note, card) → Verdict); nil: Triage::LLM on
    #   Broadcast::TriageModel's model
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV, now: Time.now,
                   active_hours: Config.get("broadcast.active_hours"), ticket_pattern: Config.get("broadcast.ticket_pattern"),
                   triage: nil, triage_parallel: Config.get("broadcast.triage_parallel"),
                   triage_deadline: Config.get("broadcast.triage_deadline"), threshold: Config.get("broadcast.threshold"))
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @env = env
      @now = now
      @active_hours = active_hours || 8
      @ticket = Broadcast::Tags.ticket_regexp(ticket_pattern, warn: ->(line) { @stderr.puts("chi broadcast: #{line}") })
      @triage = triage
      @triage_parallel = (triage_parallel || Broadcast::Triage::DEFAULT_PARALLEL).to_i
      @triage_deadline = (triage_deadline || Broadcast::Triage::DEFAULT_DEADLINE).to_f
      @threshold = (threshold || Broadcast::Triage::DEFAULT_THRESHOLD).to_f
    end

    # @return [Integer] exit status: 0 done (skipped sessions included),
    #   1 refused, nothing to send to or a delivery failed, 2 usage
    def run
      options = parse
      return options if options.is_a?(Integer)

      unless @env[PARENT_ENV].to_s.empty?
        error_line("chi broadcast: chi broadcast is for your user, not an agent")
        return 1
      end

      text = utf8(options[:text] || read_stdin)
      return usage_error("no note text: pass -m TEXT or pipe it in") unless text

      begin
        text = SessionInbox.checked_text(text)
        limit = SessionInbox::NOTE_MAX_BYTES - BODY_ROOM
        if text.bytesize > limit
          raise SessionInbox::NoteRejected, "the note is #{text.bytesize} bytes; a broadcast takes up to #{limit} " \
                                            "(16 KiB less room for the line chi adds)"
        end
      rescue SessionInbox::NoteRejected => e
        error_line("chi broadcast: #{e.message}")
        return 1
      end

      broadcast(text, all: options[:all], dry_run: options[:dry_run])
    end

    private

    def command_name = "chi broadcast"

    def parse
      parsed = parse_flags(FLAGS, @argv)
      parsed.is_a?(Integer) ? parsed : parsed.options
    end

    # @return [Integer] exit status
    def broadcast(text, all:, dry_run:)
      recipients = Broadcast::Recipients.list(state_dir: @state_dir, active_hours: @active_hours, now: @now)
      if recipients.empty?
        error_line("chi broadcast: no sessions to send to: none runs now or ended a turn in the last " \
                   "#{format_hours(@active_hours)} (chi sessions list --scope=all)")
        return 1
      end

      note_tags = Broadcast::Tags.of_text(text, from: "note", ticket: @ticket)
      cards = recipients.to_h { |r| [r.id, Broadcast::ScopeCards.build(r, state_dir: @state_dir, ticket: @ticket)] }
      @stdout.puts("broadcast#{" (dry run: nothing is delivered)" if dry_run}  #{headline(text)}")
      @stdout.puts("note tags: #{note_tags.empty? ? "none" : note_tags.map(&:label).join(" · ")}") if dry_run
      @stdout.flush
      decisions = decide(text, recipients, cards, note_tags, all: all)
      decisions = decisions.select(&:deliver?) + decisions.reject(&:deliver?)
      @stdout.puts("triage model: #{@triage_choice.target&.label || "none"} (#{@triage_choice.setting})") if dry_run && @triage_choice
      return dry_run(decisions, cards) if dry_run

      deliver_all(decisions, text)
    end

    # Every recipient's verdict: a chi REPL takes no notes, --all takes the
    # rest, else Broadcast::Triage (tags, the scope line, the model).
    # @return [Array<Decision>] in +recipients+' order
    def decide(text, recipients, cards, note_tags, all:)
      fixed = recipients.to_h do |r|
        verdict = if r.repl?
                    Broadcast::Triage::Verdict.new(relevant: false, p: nil, reason: "open in a chi REPL", by: "repl")
                  elsif all
                    Broadcast::Triage::Verdict.new(relevant: true, p: nil, reason: "--all", by: "all")
                  end
        [r.id, verdict]
      end
      judged = recipients.reject { |r| fixed[r.id] }.map { |r| cards.fetch(r.id) }
      triaged = Broadcast::Triage.verdicts(text, judged, note_tags: note_tags, new_backend: method(:triage_backend),
                                                         parallel: @triage_parallel, deadline: @triage_deadline)
      recipients.map { |r| Decision.new(recipient: r, verdict: fixed[r.id] || triaged.fetch(r.id)) }
    end

    # One triage backend for a thread (Triage.judge_all): the injected
    # one, or Triage::LLM on the triage model, resolved once; with no
    # model to ask, one that delivers unchecked and says why.
    def triage_backend(cancel)
      return @triage.call(cancel) if @triage

      choice = triage_choice
      return UncheckedBackend.new("no triage model: #{choice.problem}") unless choice.target

      Broadcast::Triage::LLM.new(target: choice.target, timeout: @triage_deadline, threshold: @threshold,
                                 cancel_controller: cancel)
    end

    def triage_choice
      (@triage_lock ||= Mutex.new).synchronize do
        @triage_choice ||= Broadcast::TriageModel.resolve.tap do |choice|
          error_line("chi broadcast: no triage model: #{choice.problem}; delivering unchecked") unless choice.target
        end
      end
    end

    # A triage backend with no model: every card it gets is delivered
    # unchecked, +why+ in the reason.
    UncheckedBackend = Data.define(:why) do
      def judge(_note, _card) = Broadcast::Triage.unchecked(why)
    end

    def dry_run(decisions, cards)
      decisions.each do |d|
        @stdout.puts(line(d.recipient, d.deliver? ? "would get it" : "skipped", d.verdict.reason, width: 12))
        @stdout.puts(cards.fetch(d.recipient.id).to_s.gsub(/^/, "          "))
      end
      delivered = decisions.count(&:deliver?)
      @stdout.puts("would deliver #{delivered} · skipped #{decisions.size - delivered}#{unchecked_summary(decisions)}")
      0
    end

    def deliver_all(decisions, text)
      ok = true
      lines = decisions.map do |d|
        next [d.recipient, false, "skipped", d.verdict.reason] unless d.deliver?

        result = NoteDelivery.deliver(d.recipient.id, text: body(text, d.verdict), source: SOURCE, state_dir: @state_dir)
        next [d.recipient, false, "skipped", "open in a chi REPL"] unless result.delivered?

        [d.recipient, true, "delivered", "#{d.verdict.reason}#{"; waits for its next start" if result.status == :waits}"]
      rescue SessionInbox::NoteRejected, SystemCallError => e
        ok = false
        [d.recipient, false, "failed", e.message]
      end
      lines.sort_by.with_index { |(_, delivered), i| [delivered ? 0 : 1, i] }.each do |recipient, _, word, why|
        @stdout.puts(line(recipient, word, why))
      end
      delivered = lines.count { |_, d| d }
      @stdout.puts("delivered #{delivered} · skipped #{lines.size - delivered}#{unchecked_summary(decisions)}")
      ok ? 0 : 1
    end

    # " · 2 unchecked: triage deadline" when some were delivered without a
    # verdict (the desktop helper shows only this line), else "".
    def unchecked_summary(decisions)
      unchecked = decisions.map(&:verdict).select(&:unchecked?)
      return "" if unchecked.empty?

      whys = unchecked.map { |v| v.reason.delete_prefix("unchecked: ").sub(/\s*[("].*\z/m, "") }.uniq
      " · #{unchecked.size} unchecked: #{whys.join(", ")}"
    end

    # What a recipient gets: the user's text first (the terminal's "note
    # from broadcast: …" line shows its start), then a line saying when it
    # was shared (a session with no worker may read it days later; the
    # note's header has the time only) and, for a tag match, why it reached
    # this session. No instruction: the system prompt says what a broadcast
    # note asks.
    def body(text, verdict)
      shared = "Shared by your user on #{@now.localtime.strftime("%Y-%m-%d %H:%M")}"
      return "#{text}\n(#{shared} with every active session.)" if verdict.by == "all"
      return "#{text}\n(#{shared} with the sessions it may concern.)" unless verdict.match

      because = verdict.match.because
      because = "#{because[0, BECAUSE_CHARS - 1]}…" if because.length > BECAUSE_CHARS
      "#{text}\n(#{shared} with the sessions it may concern; it reached you because #{because}.)"
    end

    def line(recipient, word, why, width: 9) = "#{recipient.short_id}  #{word.ljust(width)}  #{why}"

    # The note's first line, quoted and cut, for the output's head.
    def headline(text)
      lines = text.lines
      first = lines.first.to_s.strip
      first = "#{first[0, 59]}…" if first.length > 60
      first = "#{first} …" if lines.size > 1 && !first.end_with?("…")
      "\"#{first}\""
    end

    def format_hours(hours)
      value = hours.to_f
      "#{value == value.round ? value.round : value} #{value == 1 ? "hour" : "hours"}"
    end
  end
end
