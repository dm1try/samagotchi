# frozen_string_literal: true

require_relative "config"
require_relative "session"
require_relative "session_inbox"
require_relative "note_delivery"
require_relative "broadcast/recipients"
require_relative "broadcast/scope_card"
require_relative "broadcast/tags"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi broadcast`: share a note with every session it may concern,
  # without picking them. Each recipient (Broadcast::Recipients) that shares
  # a tag with the note (Broadcast::Tags) gets it as a context note from
  # "broadcast"; --all gives it to every recipient. The rest are listed as
  # skipped, with why. For the user only: refused inside a chi session.
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
        your prompts there or its attached context. The rest are skipped.
        -m TEXT    the note; without it, stdin is read
        --all      every recipient, tag or not
        --dry-run  show each recipient's scope card, tags and verdict; deliver nothing
        For you, not for an agent: refused inside a chi session.
        One session or a few by id: chi note. See docs/broadcast.md.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS, args: false) do |f|
      f.switch "--all"
      f.switch "--dry-run"
      f.value "-m", "--message", key: :text
    end

    # One recipient's verdict. +match+: the tag that delivers it (nil with
    # --all or none); +skip+: why it is skipped, else nil.
    Verdict = Data.define(:recipient, :match, :skip) do
      def deliver? = skip.nil?
    end

    # @param argv [Array<String>] the arguments after "broadcast"
    # @param active_hours [Numeric, nil] broadcast.active_hours (config)
    # @param ticket_pattern [String, nil] broadcast.ticket_pattern (config)
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV, now: Time.now,
                   active_hours: Config.get("broadcast.active_hours"), ticket_pattern: Config.get("broadcast.ticket_pattern"))
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @env = env
      @now = now
      @active_hours = active_hours || 8
      @ticket = Broadcast::Tags.ticket_regexp(ticket_pattern, warn: ->(line) { @stderr.puts("chi broadcast: #{line}") })
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
      verdicts = recipients.map { |r| verdict(r, cards.fetch(r.id), note_tags, all: all) }
      verdicts = verdicts.select(&:deliver?) + verdicts.reject(&:deliver?)

      @stdout.puts("broadcast#{" (dry run: nothing is delivered)" if dry_run}  #{headline(text)}")
      @stdout.puts("note tags: #{note_tags.empty? ? "none" : note_tags.map(&:label).join(" · ")}") if dry_run
      return dry_run(verdicts, cards) if dry_run

      deliver_all(verdicts, text)
    end

    def verdict(recipient, card, note_tags, all:)
      return Verdict.new(recipient: recipient, match: nil, skip: "open in a chi REPL") if recipient.repl?

      match = Broadcast::Tags.match(note_tags, card.tags)
      skip = "no tag match (not checked: no triage yet)" unless all || match
      Verdict.new(recipient: recipient, match: match, skip: skip)
    end

    def dry_run(verdicts, cards)
      verdicts.each do |v|
        @stdout.puts(line(v.recipient, v.deliver? ? "would get it" : "skipped", reason(v), width: 12))
        @stdout.puts(cards.fetch(v.recipient.id).to_s.gsub(/^/, "          "))
      end
      delivered = verdicts.count(&:deliver?)
      @stdout.puts("would deliver #{delivered} · skipped #{verdicts.size - delivered}")
      0
    end

    def deliver_all(verdicts, text)
      ok = true
      lines = verdicts.map do |v|
        next [v.recipient, false, "skipped", v.skip] unless v.deliver?

        result = NoteDelivery.deliver(v.recipient.id, text: body(text, v.match), source: SOURCE, state_dir: @state_dir)
        next [v.recipient, false, "skipped", "open in a chi REPL"] unless result.delivered?

        [v.recipient, true, "delivered", "#{reason(v)}#{"; waits for its next start" if result.status == :waits}"]
      rescue SessionInbox::NoteRejected, SystemCallError => e
        ok = false
        [v.recipient, false, "failed", e.message]
      end
      lines.sort_by.with_index { |(_, delivered), i| [delivered ? 0 : 1, i] }.each do |recipient, _, word, why|
        @stdout.puts(line(recipient, word, why))
      end
      delivered = lines.count { |_, d| d }
      @stdout.puts("delivered #{delivered} · skipped #{lines.size - delivered}")
      ok ? 0 : 1
    end

    # What a recipient gets: the user's text first (the terminal's "note
    # from broadcast: …" line shows its start), then a line saying when it
    # was shared (a session with no worker may read it days later; the
    # note's header has the time only) and why it reached this session. No
    # instruction: the system prompt says what a broadcast note asks.
    def body(text, match)
      shared = "Shared by your user on #{@now.localtime.strftime("%Y-%m-%d %H:%M")}"
      return "#{text}\n(#{shared} with every active session.)" unless match

      because = match.because
      because = "#{because[0, BECAUSE_CHARS - 1]}…" if because.length > BECAUSE_CHARS
      "#{text}\n(#{shared} with the sessions it may concern; it reached you because #{because}.)"
    end

    def reason(verdict)
      verdict.skip || verdict.match&.reason || "--all"
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

    # Only a pipe or a file is read, as chi note does: a terminal or a
    # socket a launcher passes down may never close.
    def read_stdin
      return nil if @stdin.respond_to?(:tty?) && @stdin.tty?

      if @stdin.respond_to?(:stat)
        stat = @stdin.stat
        return nil unless stat.pipe? || stat.file?
      end

      @stdin.read
    end

    # The note as UTF-8 whatever the locale says (see NoteCommand#utf8).
    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end
  end
end
