# frozen_string_literal: true

require "securerandom"
require_relative "config"
require_relative "session"
require_relative "session_inbox"
require_relative "note_delivery"
require_relative "broadcast/recipients"
require_relative "broadcast/scope_card"
require_relative "broadcast/tags"
require_relative "broadcast/triage"
require_relative "broadcast/triage_model"
require_relative "broadcast/triage_log"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi broadcast`: share a note with every session it may concern,
  # without picking them. Each recipient (Broadcast::Recipients) that shares
  # a tag with the note (Broadcast::Tags) gets it as a context note from
  # "broadcast", and a triage model judges the rest (Broadcast::Triage);
  # --all gives it to every recipient. The rest are listed as skipped, with
  # why. Each broadcast's verdicts go to Broadcast::TriageLog (`chi
  # broadcast log`), and `chi broadcast deliver` gives one to sessions it
  # skipped. For the user only: refused inside a chi session.
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
             chi broadcast log [--last N] [--format json]
             chi broadcast deliver BROADCAST_ID (ID|PREFIX)...
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
        It prints the broadcast's id (b-7f3a1c9e), then a line per recipient.
        log: the last N broadcasts (5) and each recipient's verdict, from
        the triage log; --format json for a script.
        deliver: the broadcast to sessions it skipped, after all (kept in
        the log as a correction).
        For you, not for an agent: refused inside a chi session.
        One session or a few by id: chi note. See docs/broadcast.md.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS, args: false) do |f|
      f.switch "--all"
      f.switch "--dry-run"
      f.value "-m", "--message", key: :text
    end

    LOG_FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS, args: false) do |f|
      f.value "--last"
      f.value "--format"
    end

    DELIVER_FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS)

    # The broadcasts `chi broadcast log` shows by default.
    LOG_LAST = 5

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
    # @param log [Broadcast::TriageLog, nil] nil: the default path's
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, env: ENV, now: Time.now,
                   active_hours: Config.get("broadcast.active_hours"), ticket_pattern: Config.get("broadcast.ticket_pattern"),
                   triage: nil, triage_parallel: Config.get("broadcast.triage_parallel"),
                   triage_deadline: Config.get("broadcast.triage_deadline"), threshold: Config.get("broadcast.threshold"),
                   log: nil)
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
      @log = log || Broadcast::TriageLog.new
    end

    # @return [Integer] exit status: 0 done (skipped sessions included),
    #   1 refused, nothing to send to or a delivery failed, 2 usage
    def run
      case @argv.first
      when "log" then return run_log(@argv.drop(1))
      when "deliver" then return run_deliver(@argv.drop(1))
      end

      options = parse
      return options if options.is_a?(Integer)
      return refused if agent?

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

    # Inside a chi session (any SAMAGOTCHI_PARENT_SESSION, "chi" included):
    # an agent runs it.
    def agent? = !@env[PARENT_ENV].to_s.empty?

    def refused
      error_line("chi broadcast: chi broadcast is for your user, not an agent")
      1
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
      id = "b-#{SecureRandom.hex(4)}" unless dry_run
      @stdout.puts("broadcast #{id || "(dry run: nothing is delivered)"}  #{headline(text)}")
      @stdout.puts("note tags: #{note_tags.empty? ? "none" : note_tags.map(&:label).join(" · ")}") if dry_run
      @stdout.flush
      decisions = decide(text, recipients, cards, note_tags, all: all)
      decisions = decisions.select(&:deliver?) + decisions.reject(&:deliver?)
      @stdout.puts("triage model: #{@triage_choice.target&.label || "none"} (#{@triage_choice.setting})") if dry_run && @triage_choice
      return dry_run(decisions, cards) if dry_run

      deliver_all(Broadcast::TriageLog::Record.new(id: id, at: @now, text: text, note_tags: note_tags.map(&:label),
                                                   triage_model: @triage_choice&.target&.label, recipients: [],
                                                   corrections: []), decisions, cards)
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

    # Delivers +broadcast+ (a TriageLog::Record with no recipients yet) per
    # +decisions+, prints a line per recipient and the summary, and logs it.
    def deliver_all(broadcast, decisions, cards)
      ok = true
      lines = decisions.map do |d|
        next [d, "skipped", d.verdict.reason] unless d.deliver?

        result = NoteDelivery.deliver(d.recipient.id, text: body(broadcast.text, d.verdict), source: SOURCE,
                                                      state_dir: @state_dir)
        next [d, "skipped", "open in a chi REPL"] unless result.delivered?

        [d, "delivered", "#{d.verdict.reason}#{"; waits for its next start" if result.status == :waits}"]
      rescue SessionInbox::NoteRejected, SystemCallError => e
        ok = false
        [d, "failed", e.message]
      end
      lines.sort_by.with_index { |(_, word), i| [word == "delivered" ? 0 : 1, i] }.each do |d, word, why|
        @stdout.puts(line(d.recipient, word, why))
      end
      delivered = lines.count { |_, word| word == "delivered" }
      @stdout.puts("delivered #{delivered} · skipped #{lines.size - delivered}#{unchecked_summary(decisions)}")
      write_log(broadcast, lines, cards)
      ok ? 0 : 1
    end

    # The broadcast's verdicts into the triage log; a log that can't be
    # written is a warning, not a failed broadcast.
    def write_log(broadcast, lines, cards)
      entries = lines.map do |d, word, why|
        verdict = d.verdict
        Broadcast::TriageLog::Entry.new(session: d.recipient.id, result: word, p: verdict.p, reason: why, by: verdict.by,
                                        tags: cards.fetch(d.recipient.id).tags.map(&:label))
      end
      @log.append_broadcast(id: broadcast.id, at: broadcast.at, text: broadcast.text, note_tags: broadcast.note_tags,
                            triage_model: broadcast.triage_model, recipients: entries)
    rescue SystemCallError => e
      error_line("chi broadcast: the triage log #{@log.path} couldn't be written: #{e.message}")
    end

    # `chi broadcast log`. @return [Integer] exit status
    def run_log(argv)
      parsed = parse_flags(LOG_FLAGS, argv)
      return parsed if parsed.is_a?(Integer)
      return refused if agent?

      options = parsed.options
      last = options[:last] ? Integer(options[:last], exception: false) : LOG_LAST
      return usage_error("--last takes a positive number") unless last&.positive?
      return usage_error("--format takes json") unless [nil, "json"].include?(options[:format])

      records = @log.records.last(last)
      if options[:format] == "json"
        @stdout.puts(JSON.pretty_generate(records.map(&:to_json_hash)))
        return 0
      end
      @stdout.puts("no broadcasts in the log yet (#{@log.path})") if records.empty?
      records.each { |record| print_record(record) }
      0
    end

    def print_record(record)
      @stdout.puts("#{record.id}  #{record.at.localtime.strftime("%Y-%m-%d %H:%M")}  #{headline(record.text)}")
      record.recipients.each { |e| @stdout.puts("  #{e.session[0, 8]}  #{e.result.ljust(9)}  #{e.reason}") }
      delivered = record.recipients.count { |e| e.result == "delivered" }
      @stdout.puts("  delivered #{delivered} · skipped #{record.recipients.size - delivered}")
      record.corrections.each do |c|
        sessions = c.sessions.map { |d| "#{d.session[0, 8]}#{" (#{d.result})" unless d.result == "delivered"}" }
        @stdout.puts("  #{c.at.localtime.strftime("%Y-%m-%d %H:%M")} delivered anyway: #{sessions.join(", ")}")
      end
    end

    # `chi broadcast deliver BROADCAST_ID SESSION...`: the logged note to
    # sessions it skipped. @return [Integer] exit status
    def run_deliver(argv)
      parsed = parse_flags(DELIVER_FLAGS, argv)
      return parsed if parsed.is_a?(Integer)
      return refused if agent?

      given, *sessions = parsed.args
      return usage_error("give a broadcast id and the sessions to deliver it to") if given.nil? || sessions.empty?

      record = begin
        @log.find(given)
      rescue Broadcast::TriageLog::NotFound => e
        error_line("chi broadcast: #{e.message}")
        return 1
      end
      ids = sessions.map { |given| resolve_session(given) }
      results = ids.compact.uniq.map { |id| deliver_anyway(record, id) }
      unless results.empty?
        begin
          @log.append_correction(id: record.id, at: @now, sessions: results)
        rescue SystemCallError => e
          error_line("chi broadcast: the triage log #{@log.path} couldn't be written: #{e.message}")
        end
      end
      # Done when every session named has the note now.
      ids.all? && results.all? { |d| ["delivered", "had it"].include?(d.result) } ? 0 : 1
    end

    # The full id +given+ names (an id or the start of one), or nil after
    # saying why there is none.
    def resolve_session(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      Session.load(id, state_dir: @state_dir) # raises ArgumentError when there is no such session
      id
    rescue ArgumentError => e
      error_line("chi broadcast: #{e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"}")
      nil
    rescue SystemCallError => e
      error_line("chi broadcast: session #{given} can't be read: #{e.message}")
      nil
    end

    # @param id [String] a full session id (#resolve_session)
    # @return [Broadcast::TriageLog::Delivery]
    def deliver_anyway(record, id)
      if record.delivered?(id)
        @stdout.puts(line_for(id, "skipped", "it got #{record.id} already"))
        return Broadcast::TriageLog::Delivery.new(session: id, result: "had it")
      end

      result = NoteDelivery.deliver(id, text: passed_on_body(record), source: SOURCE, state_dir: @state_dir)
      unless result.delivered?
        @stdout.puts(line_for(id, "skipped", "open in a chi REPL"))
        return Broadcast::TriageLog::Delivery.new(session: id, result: "refused")
      end

      @stdout.puts(line_for(id, "delivered", "by hand#{"; waits for its next start" if result.status == :waits}"))
      Broadcast::TriageLog::Delivery.new(session: id, result: "delivered")
    rescue SessionInbox::NoteRejected, SystemCallError => e
      @stdout.puts(line_for(id, "failed", e.message))
      Broadcast::TriageLog::Delivery.new(session: id, result: "failed")
    end

    # A logged broadcast passed on by hand: as #body words it, dated when
    # it was shared.
    def passed_on_body(record)
      shared = "Shared by your user on #{record.at.localtime.strftime("%Y-%m-%d %H:%M")}"
      "#{record.text}\n(#{shared} with the sessions it may concern; your user passed it on to this session.)"
    end

    def line_for(id, word, why) = "#{id[0, 8]}  #{word.ljust(9)}  #{why}"

    # " · 2 unchecked: triage deadline" when some were delivered without a
    # verdict (the desktop helper shows only this line), else "". Each
    # reason ends before its details: a parenthesis, a quote, or a single
    # quote after a space ("host_ref 'lan' is …", not "isn't").
    def unchecked_summary(decisions)
      unchecked = decisions.map(&:verdict).select(&:unchecked?)
      return "" if unchecked.empty?

      whys = unchecked.map { |v| v.reason.delete_prefix("unchecked: ").sub(/(?:\s*[("]|\s+').*\z/m, "") }.uniq
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
