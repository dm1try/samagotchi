# frozen_string_literal: true

require "date"
require "json"
require "securerandom"
require "time"
require "fileutils"

require_relative "atomic_file"
require_relative "archive_store"
require_relative "client_id"
require_relative "config"
require_relative "continue_offer"
require_relative "delivery"
require_relative "log"
require_relative "session"
require_relative "session_chain"
require_relative "session_inbox"
require_relative "session_manager"
require_relative "session_row"
require_relative "worker_link"

module Samagotchi
  # Durable schedules: `chi schedule` and the schedule tools. A schedule lives
  # in one file next to the sessions and outlives every worker: a tick run by
  # cron, systemd, launchd or chi web's hub (docs/scheduling.md) finds the
  # entries whose time has come and runs one of two things against a session:
  #
  #   chain (default) — the next link of the session's chain
  #     (SessionContinue.run): the previous link is archived, the new one
  #     starts with its recap and last answer. "The next run of the same
  #     routine", and the reason a long-lived coordinator's context stays
  #     healthy.
  #   same — the prompt is queued as a turn of the session itself
  #     (SessionManager.deliver_turn, delivery: queue), waking a worker when
  #     none runs.
  #
  # Unlike register_reminder (ReminderStore, in a live worker's memory, which
  # keeps that worker up), a schedule needs no worker at all: that is the whole
  # point of it. A schedule never holds an idle worker up.
  #
  # Every read-modify-write of the file holds flock on schedules.lock, so a
  # cron tick and a hub tick (or two crontabs, or `chi schedule add` from a
  # terminal) never lose an update. The tick holds that lock only for the
  # read-modify-write, never across the action: SessionContinue.run waits up to
  # 30 s for a recap and 5 s for an archive, and an `add` must not wait on it.
  class Schedules
    FILE = "schedules.json"
    LOCK = "schedules.lock"
    VERSION = 1

    CHAIN = "chain"
    SAME = "same"
    MODES = [CHAIN, SAME].freeze
    CATCH_UP = %w[once none].freeze
    WEEKDAYS = { 1 => "Mon", 2 => "Tue", 3 => "Wed", 4 => "Thu", 5 => "Fri", 6 => "Sat", 7 => "Sun" }.freeze
    # A schedule prompt is a chain link's first message or a turn's prompt: the
    # same limit the note inbox uses.
    PROMPT_MAX_BYTES = SessionInbox::NOTE_MAX_BYTES
    # Seconds a tick waits for a live worker's GET /activity.
    ACTIVITY_TIMEOUT = 2.0
    # Refusals that mean "not now" rather than "this schedule is broken".
    SKIP_REASONS = %w[busy queued offer busy_child queued_child offer_child continued open_children].freeze

    # The add itself is wrong (no prompt, two recurrence kinds, a scratch
    # target): a usage error, exit 2.
    class Usage < StandardError; end

    # One schedule as the file stores it. `anchor` never changes (the chain's
    # root and the provenance of the schedule); `head` is the chain's current
    # link, re-anchored after every successful chain firing — that is what
    # makes keep_links pruning provably safe: everything deleted is behind it.
    Entry = Data.define(:id, :title, :anchor, :head, :mode, :prompt, :recurrence, :busy, :catch_up,
                        :keep_links, :max_failures, :max_skips, :next_due, :last_fired, :last_result,
                        :firing_since, :failures, :skips, :enabled, :created_at) do
      # The recurrence comes back from JSON with string keys: every reader of
      # it below matches on `recurrence[:kind]`, so it is symbolised here once.
      def self.from_h(hash)
        recurrence = hash["recurrence"]
        new(**hash.transform_keys(&:to_sym),
            recurrence: recurrence.is_a?(Hash) ? recurrence.transform_keys(&:to_sym) : recurrence)
      end

      def due?(now)
        Time.iso8601(next_due.to_s) <= now
      rescue ArgumentError
        false
      end

      # `every 30m`, `Mon 09:00`, `2026-11-20 09:00` — what `list` prints.
      def recurrence_words
        case recurrence[:kind]
        when "every" then "every #{recurrence[:interval]}"
        when "weekday" then "#{WEEKDAYS[recurrence[:weekday]]} #{recurrence[:time]}"
        when "date" then Time.iso8601(recurrence[:at]).localtime.strftime("%Y-%m-%d %H:%M")
        else recurrence.to_s
        end
      rescue StandardError
        recurrence.to_s
      end

      def target_words = "#{mode} · #{head.to_s[0, 8]}"
    end

    # What one entry did in a tick: "fired", "skipped", "missed", "failed" or
    # "dry" (a --dry-run's "would fire"). +detail+ is the reason.
    Outcome = Data.define(:id, :title, :status, :detail, :entry) do
      def initialize(id:, status:, title: nil, detail: nil, entry: nil) = super
    end

    # A whole tick.
    Tick = Data.define(:locked, :outcomes) do
      def initialize(locked: false, outcomes: []) = super

      def fired = outcomes.select { |outcome| outcome.status == "fired" }
    end

    # @param state_dir [String] the sessions' directory; the schedule file and
    #   its lock sit next to them
    # @param clock [#call] "now", as a Time
    def initialize(state_dir: nil, clock: -> { Time.now })
      @state_dir = state_dir || Session.default_state_dir
      @clock = clock
    end

    attr_reader :state_dir

    def path = File.join(@state_dir, FILE)
    def lock_path = File.join(@state_dir, LOCK)

    # @param include_disabled [Boolean] the disabled and the fired one-offs too
    # @return [Array<Entry>] every entry, the earliest due first
    def entries(include_disabled: false)
      list = read.sort_by { |entry| [entry.next_due.to_s, entry.id] }
      include_disabled ? list : list.select(&:enabled)
    end

    # @param id_or_name [String] an id, a unique prefix of one, or a title
    # @return [Entry, nil]
    def lookup(id_or_name)
      given = id_or_name.to_s.strip
      return nil if given.empty?

      list = read
      exact = list.find { |entry| entry.id == given }
      return exact if exact

      prefixes = list.select { |entry| entry.id.start_with?(given) }
      return prefixes.first if prefixes.size == 1

      list.find { |entry| entry.title.to_s.casecmp?(given) }
    end

    # Add a schedule. +target+ is the session it runs against (an id or a
    # unique prefix of one); +recurrence+ is one kind, from #recurrence.
    # @return [Entry]
    # @raise [Usage] the add is wrong
    # @raise [Session::NotFound, Session::AmbiguousId] no such session
    def add(target:, prompt:, recurrence:, title: nil, mode: CHAIN, catch_up: nil, keep_links: nil,
            max_failures: nil, max_skips: nil)
      raise Usage, "a schedule needs a session to run against" if target.to_s.strip.empty?
      raise Usage, "mode must be one of #{MODES.join(", ")}" unless MODES.include?(mode)

      given_catch_up = catch_up.nil? || catch_up.to_s.strip.empty? ? Config.get("schedule.default_catch_up") : catch_up.to_s.strip
      raise Usage, "catch_up must be one of #{CATCH_UP.join(", ")}" unless CATCH_UP.include?(given_catch_up)

      prompt = prompt.to_s
      raise Usage, "a schedule needs a prompt" if prompt.strip.empty?
      if prompt.bytesize > PROMPT_MAX_BYTES
        raise Usage, "the prompt is #{prompt.bytesize} bytes; the limit is 16 KiB (#{PROMPT_MAX_BYTES} bytes)"
      end

      anchor = Session.resolve!(target.to_s, state_dir: @state_dir)
      if Session.load(anchor, state_dir: @state_dir).scratch
        raise Usage, "a scratch session is deleted when its terminal leaves: a schedule cannot run against one"
      end

      now = @clock.call
      entry = Entry.new(
        id: SecureRandom.hex(8), title: title.to_s.strip.empty? ? nil : title.to_s.strip,
        anchor: anchor, head: anchor, mode: mode, prompt: prompt, recurrence: recurrence, busy: "skip",
        catch_up: given_catch_up,
        keep_links: int_or_default(keep_links, "schedule.default_keep_links", 5, min: 0),
        max_failures: int_or_default(max_failures, "schedule.default_max_failures", 3, min: 1),
        max_skips: int_or_default(max_skips, "schedule.default_max_skips", 12, min: 1),
        next_due: next_due_for(recurrence, from: now).utc.iso8601,
        last_fired: nil, last_result: nil, firing_since: nil,
        failures: 0, skips: 0, enabled: true, created_at: now.utc.iso8601
      )
      write_under_lock { |list| list << entry }
      entry
    end

    # @return [Entry, nil] nil when no schedule matches
    def cancel(id_or_name) = change(id_or_name, delete: true)
    def enable(id_or_name) = change(id_or_name, enabled: true)
    def disable(id_or_name) = change(id_or_name, enabled: false)

    # One pass over the file: the entries due now, each checked for busy, then
    # advanced and (outside the lock) fired.
    # @param dry_run [Boolean] report what would fire, change nothing
    # @param now [Time] "now"
    # @return [Tick]
    def tick(dry_run: false, now: @clock.call)
      outcomes = []
      pending = []
      index = nil

      FileUtils.mkdir_p(@state_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          # Another tick (cron and the hub, or two crontabs) is already at
          # work: never two firings of the same entry.
          return Tick.new(locked: true, outcomes: [])
        end

        list = read
        due = list.select { |entry| entry.enabled && entry.due?(now) }
        return Tick.new(locked: false, outcomes: []) if due.empty?

        # One session listing for the whole tick: a chain walk re-globbing
        # every session per call is the tick's dominant cost.
        index = Index.new(@state_dir)
        updated = list.dup
        due.each do |entry|
          position = updated.index { |candidate| candidate.id == entry.id }
          verdict = check(entry, index)
          if verdict
            kind, reason = verdict
            unless dry_run
              updated[position] = kind == :skip ? skipped(entry, reason) : failed(entry, reason)
            end
            outcomes << Outcome.new(id: entry.id, title: entry.title, status: kind == :skip ? "skipped" : "failed",
                                    detail: reason, entry: entry)
            next
          end
          if dry_run
            outcomes << Outcome.new(id: entry.id, title: entry.title, status: "dry", detail: entry.recurrence_words, entry: entry)
            next
          end
          if entry.catch_up == "none" && late?(entry, now)
            updated[position] = reschedule(entry, now)
            outcomes << Outcome.new(id: entry.id, title: entry.title, status: "missed", detail: "past its time", entry: entry)
            next
          end
          advanced = advance(entry, now)
          updated[position] = advanced
          pending << advanced
        end
        write(list: updated) unless dry_run
      end

      pending.each { |entry| outcomes << fire_and_record(entry, index) }
      Tick.new(locked: false, outcomes: outcomes)
    end

    # Fire one entry now, whatever its next_due says (`chi schedule run-now`).
    # @return [Outcome]
    def run_now(id_or_name)
      entry = lookup(id_or_name)
      return Outcome.new(id: id_or_name.to_s, status: "failed", detail: "no such schedule") if entry.nil?

      index = Index.new(@state_dir)
      verdict = check(entry, index)
      if verdict
        return Outcome.new(id: entry.id, title: entry.title, status: verdict.first == :skip ? "skipped" : "failed",
                           detail: verdict.last, entry: entry)
      end

      fire_and_record(advance(entry, @clock.call), index)
    end

    # Minutes between the hub's ticks when schedule.auto_tick is on.
    def self.tick_interval_minutes
      value = Config.get("schedule.tick_interval_minutes").to_i
      value.positive? ? value : 5
    end

    # A recurrence from the CLI's or the tool's flags.
    # @return [Hash] {kind:, ...}
    # @raise [Usage] none or more than one kind given
    def self.recurrence(every: nil, weekday: nil, time: nil, date: nil)
      kinds = [every, weekday, date].compact.reject { |value| value.to_s.strip.empty? }
      raise Usage, "a schedule needs one of --every, --weekday or --date" if kinds.empty?
      raise Usage, "give one of --every, --weekday or --date, not more" if kinds.size > 1

      if every
        raise Usage, "--time is only for --weekday" if time && !weekday

        interval = every.to_s.strip
        raise Usage, "every must be like 30m, 2h or 1d, got #{every}" unless interval.match?(/\A\d+[smhd]?\z/)

        { kind: "every", interval: interval }
      elsif weekday
        raise Usage, "--weekday needs --time HH:MM" if time.to_s.strip.empty?

        day = weekday.to_i
        raise Usage, "weekday must be 1 (Mon) to 7 (Sun), got #{weekday}" unless (1..7).cover?(day)

        { kind: "weekday", weekday: day, time: time.to_s.strip }
      else
        { kind: "date", at: Schedules.local_moment(*Schedules.parse_local(date)).utc.iso8601 }
      end
    end

    # The chain a tick walks: the sessions once, with their predecessors,
    # their successors and whether they are archived.
    class Index
      def initialize(state_dir)
        @state_dir = state_dir
        sessions = Session.list(state_dir: state_dir, include_archived: true, sort: "created_at", order: "asc")
        @by_id = sessions.to_h { |session| [session.id, session] }
        @archived = @by_id.to_h { |id, _session| [id, ArchiveStore.archived?(Session.session_dir(id, state_dir: state_dir))] }
        @nexts = {}
        sessions.each { |session| @nexts[session.continues] ||= session.id if session.continues }
      end

      def session(id) = @by_id[id]

      def gone?(id) = @by_id[id].nil?

      def archived?(id) = @archived[id]

      attr_reader :state_dir

      # The chain's latest link from +id+ on, in this one listing.
      def latest(id)
        seen = [id]
        while (following = @nexts[seen.last]) && !seen.include?(following)
          seen << following
        end
        seen.last
      end

      # A link's predecessor, or nil (a pruned or never-existing one).
      def continues(id) = @by_id[id]&.continues
    end

    def self.interval_seconds(interval)
      match = interval.to_s.strip.match(/\A(\d+)(s|m|h|d)?\z/)
      return nil unless match

      { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, nil => 60 }[match[2]] * match[1].to_i
    end

    def self.parse_clock(time)
      match = time.to_s.strip.match(/\A(\d{1,2}):(\d{1,2})\z/)
      raise Usage, "time must be HH:MM, got #{time}" unless match

      hour = match[1].to_i
      minute = match[2].to_i
      raise Usage, "time must be HH:MM, got #{time}" unless (0..23).cover?(hour) && (0..59).cover?(minute)

      [hour, minute]
    end

    def self.parse_local(text)
      match = text.to_s.strip.match(/\A(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{1,2}):(\d{2}))?\z/)
      raise Usage, "date must be YYYY-MM-DD or YYYY-MM-DDTHH:MM, got #{text}" unless match

      year = match[1].to_i
      month = match[2].to_i
      day = match[3].to_i
      hour = match[4] ? match[4].to_i : 0
      minute = match[5] ? match[5].to_i : 0
      unless (1..12).cover?(month) && (1..31).cover?(day) && (0..23).cover?(hour) && (0..59).cover?(minute)
        raise Usage, "date must be a real date, got #{text}"
      end

      [year, month, day, hour, minute]
    end

    # A local moment that exists. When the requested minute falls in a
    # spring-forward gap, the first valid minute whose wall clock is at or
    # after it.
    def self.local_moment(year, month, day, hour, minute)
      moment = Time.local(year, month, day, hour, minute)
      return moment if moment.hour == hour && moment.min == minute

      wanted = (hour * 60) + minute
      day_start = Time.local(year, month, day, 0, 0)
      1440.times do |step|
        probe = day_start + (step * 60)
        return probe if (probe.hour * 60) + probe.min >= wanted
      end
      moment
    end

    private

    def read
      return [] unless File.exist?(path)

      data = JSON.parse(File.read(path))
      Array(data["schedules"]).map { |hash| Entry.from_h(hash) }
    rescue JSON::ParserError => e
      Log.warn(:worker, "store_unreadable", error: e.class.name, msg: e.message)
      []
    end

    def write(list:)
      FileUtils.mkdir_p(@state_dir)
      body = { "version" => VERSION, "updated_at" => Time.now.utc.iso8601, "schedules" => list.map(&:to_h) }
      AtomicFile.write(path, "#{JSON.pretty_generate(body)}\n")
    end

    # Every write of the file is a read-modify-write under the lock.
    def write_under_lock
      FileUtils.mkdir_p(@state_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        list = read
        yield(list)
        write(list: list)
      end
    end

    def change(id_or_name, enabled: nil, delete: false)
      entry = nil
      given = id_or_name.to_s.strip
      write_under_lock do |list|
        position = list.index { |candidate| candidate.id == given || candidate.id.start_with?(given) }
        next if position.nil?

        entry = list[position]
        if delete
          list[position] = nil
          list.compact!
        else
          list[position] = entry.with(enabled: enabled, last_result: enabled ? "enabled" : "disabled")
        end
      end
      entry
    end

    def int_or_default(value, key, fallback, min:)
      return [value.to_i, min].max if value.to_s.strip.match?(/\A-?\d+\z/)

      configured = Config.get(key)
      configured.to_s.strip.match?(/\A-?\d+\z/) ? [configured.to_i, min].max : fallback
    end

    # The next occurrence strictly after +from+.
    def next_due_for(recurrence, from: @clock.call)
      case recurrence[:kind]
      when "every" then from + (Schedules.interval_seconds(recurrence[:interval] || "1d") || 86_400)
      when "weekday" then weekday_moment(recurrence[:weekday], recurrence[:time], from: from)
      when "date" then Time.iso8601(recurrence[:at])
      else from
      end
    end

    # The next +weekday+ at +time+ in the machine's local zone, strictly after
    # +from+ (today counts when the time is still ahead). Built with
    # Time.local, never now + 86400*n: a schedule at 09:00 keeps its wall clock
    # across a DST change, while `every 1d` drifts an hour across the fold
    # (docs/scheduling.md says so and points at --weekday for a time of day).
    def weekday_moment(weekday, time, from:)
      hour, minute = Schedules.parse_clock(time)
      start = from.to_date
      8.times do |step|
        date = start + step
        candidate = Schedules.local_moment(date.year, date.month, date.day, hour, minute)
        next if candidate <= from || candidate.wday != weekday

        return candidate
      end
      from + 86_400
    end

    # catch_up: none fires only when the tick arrives at the moment; one that
    # comes more than schedule.tick_interval_minutes after it moves to the next
    # occurrence (a machine asleep over Monday does not get a Monday run at
    # Tuesday noon).
    def late?(entry, now)
      now - Time.iso8601(entry.next_due.to_s) > Schedules.tick_interval_minutes * 60
    end

    def reschedule(entry, now)
      if entry.recurrence[:kind] == "date"
        entry.with(next_due: nil, last_result: "missed", firing_since: nil, enabled: false)
      else
        entry.with(next_due: next_due_for(entry.recurrence, from: now).utc.iso8601, last_result: "missed", firing_since: nil)
      end
    end

    # The clock advances and the entry is marked firing before the action: a
    # tick killed mid-continue cannot fire the same entry twice.
    def advance(entry, now)
      entry.with(next_due: next_due_for(entry.recurrence, from: now).utc.iso8601,
                 last_fired: now.utc.iso8601, firing_since: now.utc.iso8601, last_result: nil)
    end

    def skipped(entry, reason)
      skips = entry.skips + 1
      disabled = skips >= entry.max_skips
      entry.with(skips: skips, firing_since: nil,
                 last_result: disabled ? "disabled: #{reason}" : "skipped", enabled: !disabled)
    end

    def failed(entry, reason)
      failures = entry.failures + 1
      entry.with(failures: failures, firing_since: nil, last_result: reason, enabled: failures < entry.max_failures)
    end

    # :skip (busy now, try the next tick) or :fail (the target is gone or
    # archived); nil when the entry may fire.
    def check(entry, index)
      target, reason = target_of(entry, index)
      return [:fail, reason] if target.nil?

      busy_reason(entry, index, target)
    end

    # The session the entry would act on: for a chain, the head followed
    # through a human continue (SessionChain.latest, the same walk
    # SessionContinue.run does for `last:`); for same, the anchor itself.
    def target_of(entry, index)
      if entry.mode == CHAIN
        head = index.latest(index.gone?(entry.head) ? entry.anchor : entry.head)
        return [nil, "the chain is gone"] if index.gone?(head)
        return [nil, "archived"] if index.archived?(head)

        [head, nil]
      else
        return [nil, "the session it was made against is gone"] if index.gone?(entry.anchor)
        return [nil, "archived"] if index.archived?(entry.anchor)

        [entry.anchor, nil]
      end
    end

    # Two paths (FR7): a live worker is asked through its Bridge; with no
    # worker the files say what the tick can know.
    def busy_reason(entry, index, target)
      dir = Session.session_dir(target, state_dir: @state_dir)
      owner = SessionManager.session_owner(target, state_dir: @state_dir)
      link = WorkerLink.resolve(dir, unlink: false, owner: owner)

      if link.worker_owned?
        # A worker that has not published its Bridge yet (or is closing it):
        # nothing can be read from it, and firing now would race with it.
        return [:skip, "its worker is starting or leaving"] unless link.live?

        activity = ask_activity(link, target)
        if activity == :old
          # Its chi predates GET /activity. The file checks cannot see an open
          # tab, so a chain firing would archive under someone's terminal:
          # refuse with a restart, never silently degrade. Same mode only
          # queues a turn, so for it the files are enough.
          return [:skip, "its worker is too old to ask: chi sessions restart #{target[0, 8]}"] if entry.mode == CHAIN

          return file_busy_reason(index.session(target), dir)
        end
        return [:skip, "its worker is not answering"] if activity.nil?

        return [:skip, "a turn is running in it"] if activity[:turn_running]
        return [:skip, "a prompt is queued for it"] if activity[:input_pending]
        return [:skip, "its step-limit question waits for an answer"] if activity[:awaiting_continue]

        # A chain firing archives the session and stops its worker: a
        # terminal or a web tab on it would be cut off. A queued turn into
        # an open session is fine, so same mode does not count streams.
        return [:skip, "a terminal or a web tab is open on it"] if entry.mode == CHAIN && activity[:open_streams].to_i.positive?

        nil
      end

      file_busy_reason(index.session(target), dir)
    end

    # The worker's activity snapshot, :old when it has no /activity route, or
    # nil when it did not answer at all. A worker published its features when
    # it started, so a sidecar without "activity" is an older chi's: asking it
    # would only cost a round trip to a 404.
    def ask_activity(link, session_id)
      return :old unless Array(link.features).include?(WorkerLink::ACTIVITY_FEATURE)

      status, body = link.client(session_id, read_timeout: ACTIVITY_TIMEOUT).get("activity")
      return nil if status.nil?
      return body.transform_keys(&:to_sym) if status == 200 && body.is_a?(Hash)

      :old
    rescue StandardError => e
      Log.warn(:worker, "activity_failed", sid: session_id, error: e.class.name, msg: e.message)
      nil
    end

    # The signals RemovalPart#archive_refusal reads, from the files alone.
    def file_busy_reason(session, dir)
      return nil if session.nil?

      if SessionRow.running_or_starting?(saved_status: session.status, live: false, busy: false, updated_at: session.updated_at)
        return [:skip, "a turn is running in it"]
      end
      return [:skip, "a prompt is queued for it"] unless SessionInbox.find_new_input_files(dir).empty?

      return [:skip, "its step-limit question waits for an answer"] if session.waiting_question(live: false)&.dig(:kind) == ContinueOffer::KIND

      nil
    end

    def fire_and_record(entry, index)
      outcome = fire(entry, index)
      record(entry, outcome)
      prune(outcome.entry, index) if outcome.status == "fired" && entry.mode == CHAIN && entry.keep_links.positive?
      outcome
    end

    def fire(entry, index)
      entry.mode == CHAIN ? fire_chain(entry, index) : fire_same(entry)
    rescue StandardError => e
      # run_locked re-raises whatever spawn_continuation throws after undoing
      # the move: a spawn failure or an ENOSPC is a failure, not a skip.
      Log.warn(:worker, "fire_failed", sid: entry.anchor, id: entry.id, error: e.class.name, msg: e.message)
      Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: "#{e.class}: #{e.message}", entry: entry)
    end

    def fire_chain(entry, index)
      head, _reason = target_of(entry, index)
      return Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: "the chain is gone", entry: entry) if head.nil?

      # `last:<head>` so SessionContinue.run's own TRIES/`:moved` loop follows
      # a continue a human made between here and its lock.
      link = SessionContinue.run("last:#{head}", prompt: entry.prompt, state_dir: @state_dir)
      Outcome.new(id: entry.id, title: entry.title, status: "fired", detail: "new link #{link.id[0, 8]}",
                  entry: entry.with(head: link.id))
    rescue SessionContinue::Refused => e
      classify(entry, e.reason, e.message)
    rescue SessionManager::ArchiveRefused => e
      classify(entry, e.reason, e.message)
    end

    def fire_same(entry)
      dir = Session.session_dir(entry.anchor, state_dir: @state_dir)
      return Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: "archived", entry: entry) if ArchiveStore.archived?(dir)

      result = SessionManager.deliver_turn(entry.anchor, prompt: entry.prompt,
                                          client_id: ClientId.schedule(entry.id),
                                          delivery: Delivery::QUEUE, state_dir: @state_dir)
      if result.accepted?
        Outcome.new(id: entry.id, title: entry.title, status: "fired", detail: "queued a turn", entry: entry)
      else
        Outcome.new(id: entry.id, title: entry.title, status: "failed",
                    detail: "the turn was not accepted (#{result.status}: #{result.error || result.detail})", entry: entry)
      end
    end

    def classify(entry, reason, message)
      status = SKIP_REASONS.include?(reason.to_s) ? "skipped" : "failed"
      Outcome.new(id: entry.id, title: entry.title, status: status, detail: message, entry: entry)
    end

    # The result goes back under the lock before any pruning, so a prune that
    # raises midway cannot lose the new head.
    def record(entry, outcome)
      write_under_lock do |list|
        position = list.index { |candidate| candidate.id == entry.id }
        next if position.nil?

        stored = list[position]
        list[position] = if outcome.status == "fired"
                           # Any success clears the skip and failure counters: twelve skips
                           # spread over months do not kill a healthy schedule.
                           stored.with(head: outcome.entry.head, last_result: outcome.detail, firing_since: nil,
                                       failures: 0, skips: 0, last_fired: @clock.call.utc.iso8601)
                         elsif outcome.status == "skipped"
                           skipped(stored, outcome.detail).with(firing_since: nil)
                         else
                           failed(stored, outcome.detail)
                         end
      end
    end

    # The links behind the kept window, with the delegates that hung under
    # them: archiving a link archives its descendants, and archived sessions
    # are outside the retention sweep, so the delegate pile is the bulk of the
    # archived count. Oldest first, stopping at a link that is not archived or
    # one a worker still owns (DeleteRefused: retry at the next firing, not a
    # schedule failure). The anchor is never pruned: `last:<anchor>` must keep
    # resolving, and it is the id the user remembers.
    def prune(entry, index)
      links = []
      id = entry.head
      seen = []
      while id && !seen.include?(id)
        seen << id
        links << id
        # The link a firing just made is not in the tick's listing; every
        # older one is.
        session = index.session(id) || (File.exist?(Session.session_file(id, state_dir: @state_dir)) ? Session.load(id, state_dir: @state_dir) : nil)
        id = session&.continues
      end
      older = links[entry.keep_links..] || []
      return if older.empty?

      older.reverse_each do |link|
        next if link == entry.anchor
        break unless ArchiveStore.archived?(Session.session_dir(link, state_dir: @state_dir))

        ids = [link, *SessionManager.descendant_ids(link, @state_dir)]
        ids.each do |child|
          SessionManager.delete_session(child, state_dir: @state_dir)
        end
        Log.info(:worker, "pruned_link", sid: link, id: entry.id, links: ids.size)
      end
    rescue SessionManager::DeleteRefused => e
      Log.warn(:worker, "prune_stopped", sid: e.session_id, id: entry.id, msg: e.message)
    rescue Session::NotFound => e
      Log.warn(:worker, "prune_missing", id: entry.id, msg: e.message)
    end
  end
end
