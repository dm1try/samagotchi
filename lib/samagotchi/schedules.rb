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
require_relative "state_format"
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

    # schedules.json exists but is not readable JSON: a write would start from
    # an empty list and erase every schedule, so it refuses instead.
    class Corrupt < StandardError; end

    # One schedule as the file stores it. `anchor` never changes (the chain's
    # root and the provenance of the schedule); `head` is the chain's current
    # link, re-anchored after every firing — the link a chain continue made, or
    # the session a same-mode turn was queued into. That is what makes
    # keep_links pruning provably safe: everything deleted is behind it.
    # `due_was` is the occurrence the last tick attempted: a skip or a failure
    # puts the clock back to it.
    Entry = Data.define(:id, :title, :anchor, :head, :mode, :prompt, :recurrence, :busy, :catch_up,
                        :keep_links, :max_failures, :max_skips, :next_due, :due_was, :last_fired, :last_result,
                        :firing_since, :failures, :skips, :enabled, :created_at, :extra) do
      # The recurrence comes back from JSON with string keys: every reader of
      # it below matches on `recurrence[:kind]`, so it is symbolised here once.
      def self.from_record(record)
        fields = record.attributes
        recurrence = fields[:recurrence]
        fields[:recurrence] = recurrence.transform_keys(&:to_sym) if recurrence.is_a?(Hash)
        new(**fields, extra: record.extra)
      end

      def to_h
        fields = super
        extra = fields.delete(:extra) || {}
        extra.transform_keys(&:to_s).merge(fields.transform_keys(&:to_s))
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

    FORMAT = StateFormat.new(
      version: VERSION,
      members: [
        StateFormat.required(:id),
        StateFormat.added(:title, in_version: VERSION, default: nil),
        StateFormat.required(:anchor),
        StateFormat.added(:head, in_version: VERSION, default: ->(values) { values[:anchor] }),
        StateFormat.required(:mode),
        StateFormat.required(:prompt),
        StateFormat.required(:recurrence),
        StateFormat.added(:busy, in_version: VERSION, default: "skip"),
        StateFormat.added(:catch_up, in_version: VERSION, default: "once"),
        StateFormat.added(:keep_links, in_version: VERSION, default: 5),
        StateFormat.added(:max_failures, in_version: VERSION, default: 3),
        StateFormat.added(:max_skips, in_version: VERSION, default: 12),
        StateFormat.required(:next_due),
        StateFormat.added(:due_was, in_version: VERSION, default: nil),
        StateFormat.added(:last_fired, in_version: VERSION, default: nil),
        StateFormat.added(:last_result, in_version: VERSION, default: nil),
        StateFormat.added(:firing_since, in_version: VERSION, default: nil),
        StateFormat.added(:failures, in_version: VERSION, default: 0),
        StateFormat.added(:skips, in_version: VERSION, default: 0),
        StateFormat.added(:enabled, in_version: VERSION, default: true),
        StateFormat.added(:created_at, in_version: VERSION, default: nil),
        StateFormat.extra(:extra, in_version: VERSION)
      ]
    )

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
    #   its lock sit in the state root above it (docs/scheduling.md), so the
    #   session listing never mistakes it for a session
    # @param clock [#call] "now", as a Time
    def initialize(state_dir: nil, clock: -> { Time.now })
      @state_dir = state_dir || Session.default_state_dir
      # ~/.local/state/samagotchi for the default sessions dir; expand_path
      # first so a trailing slash does not make the parent the sessions dir.
      @store_dir = File.dirname(File.expand_path(@state_dir))
      @clock = clock
    end

    attr_reader :state_dir, :store_dir

    def path = File.join(@store_dir, FILE)
    def lock_path = File.join(@store_dir, LOCK)

    # @param include_disabled [Boolean] the disabled and the fired one-offs too
    # @return [Array<Entry>] every entry, the earliest due first
    def entries(include_disabled: false)
      list = read.entries.grep(Entry).sort_by { |entry| [entry.next_due.to_s, entry.id] }
      include_disabled ? list : list.select(&:enabled)
    end

    # @param id_or_name [String] an id, a unique prefix of one, or a title
    # @return [Entry, nil]
    # @raise [Usage] the prefix or the title names more than one schedule
    def lookup(id_or_name)
      given = id_or_name.to_s.strip
      return nil if given.empty?

      list = read.entries.grep(Entry)
      exact = list.find { |entry| entry.id == given }
      return exact if exact

      matches = ambiguous(list.select { |entry| entry.id.start_with?(given) }, given)
      return matches.first unless matches.empty?

      ambiguous(list.select { |entry| entry.title.to_s.casecmp?(given) }, given).first
    end

    # One match is the answer; several are a usage error naming them, the way
    # Session::AmbiguousId does for session prefixes.
    def ambiguous(entries, given)
      return entries if entries.size < 2

      raise Usage, "#{given} matches #{entries.size} schedules: #{entries.map(&:id).join(", ")} — use the full id"
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

      # A model told to "make sure the Monday audit is scheduled" on every
      # firing would otherwise multiply the same schedule: the chain keeps one
      # entry per thing it does, and the machine a bounded number of them.
      same = duplicate_in_chain(anchor, prompt: prompt, title: title, recurrence: recurrence)
      if same
        raise Usage, "#{same.id} already schedules this (#{same.recurrence_words}, #{mode}: #{same.prompt}); " \
                     "cancel it with chi schedule cancel #{same.id} to change it"
      end

      ids = chain_of(anchor)
      in_chain = entries.count { |entry| ids.include?(entry.anchor) || ids.include?(entry.head) }
      per_chain = per_chain_limit
      raise Usage, "this chain has #{in_chain} schedules, the limit is #{per_chain} (schedule.max_per_session)" if in_chain >= per_chain

      total = entries.size
      raise Usage, "this machine has #{total} schedules, the limit is #{total_limit} (schedule.max_total)" if total >= total_limit

      now = @clock.call
      entry = Entry.new(
        id: SecureRandom.hex(8), title: title.to_s.strip.empty? ? nil : title.to_s.strip,
        anchor: anchor, head: anchor, mode: mode, prompt: prompt, recurrence: recurrence, busy: "skip",
        catch_up: given_catch_up,
        keep_links: int_or_default(keep_links, "schedule.default_keep_links", 5, min: 0, name: "keep_links"),
        max_failures: int_or_default(max_failures, "schedule.default_max_failures", 3, min: 1),
        max_skips: int_or_default(max_skips, "schedule.default_max_skips", 12, min: 1),
        next_due: next_due_for(recurrence, from: now).utc.iso8601, due_was: nil,
        last_fired: nil, last_result: nil, firing_since: nil,
        failures: 0, skips: 0, enabled: true, created_at: now.utc.iso8601, extra: {}
      )
      write_under_lock { |file| file.entries << entry }
      entry
    end

    # @return [Entry, nil] nil when no schedule matches
    def cancel(id_or_name) = change(id_or_name, delete: true)
    def enable(id_or_name) = change(id_or_name, enabled: true)
    def disable(id_or_name) = change(id_or_name, enabled: false)

    # Every session of the chain +session_id+ belongs to: the head of the
    # chain and each link back to its root. A schedule belongs to a chain when
    # its anchor or its head is one of them.
    # @return [Array<String>]
    def chain_of(session_id)
      index = Index.new(@state_dir)
      head = index.latest(session_id)
      ids = [head]
      id = head
      while (previous = index.continues(id)) && !ids.include?(previous)
        ids << previous
        id = previous
      end
      ids
    end

    # The schedules of this session's chain — the ones the tools may touch
    # without `all: true`.
    def for_chain(session_id, include_disabled: false)
      ids = chain_of(session_id)
      entries(include_disabled: include_disabled).select { |entry| ids.include?(entry.anchor) || ids.include?(entry.head) }
    end

    # An enabled schedule of the same chain that says the same thing: the same
    # prompt and recurrence, or the same title.
    # @return [Entry, nil]
    def duplicate_in_chain(session_id, prompt:, title:, recurrence:)
      given_title = title.to_s.strip
      ids = chain_of(session_id)
      entries.find do |entry|
        next unless ids.include?(entry.anchor) || ids.include?(entry.head)

        (entry.prompt == prompt && entry.recurrence == recurrence) ||
          (!given_title.empty? && entry.title.to_s.strip.casecmp?(given_title))
      end
    end

    # How many enabled schedules one chain may hold, and one machine.
    def per_chain_limit = positive_config("schedule.max_per_session", 10)
    def total_limit = positive_config("schedule.max_total", 50)

    # One pass over the file: the entries due now, each checked for busy, then
    # advanced and (outside the lock) fired.
    # @param dry_run [Boolean] report what would fire, change nothing
    # @param now [Time] "now"
    # @return [Tick]
    def tick(dry_run: false, now: @clock.call)
      outcomes = []
      pending = []
      index = nil

      FileUtils.mkdir_p(@store_dir)
      FileUtils.mkdir_p(@state_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          # Another tick (cron and the hub, or two crontabs) is already at
          # work: never two firings of the same entry.
          return Tick.new(locked: true, outcomes: [])
        end

        file = read
        list = file.entries.grep(Entry)
        # Ordered by the moment each entry is due, then id: with one chain
        # firing per tick, the entries of that chain take turns (a skipped
        # entry keeps its `next_due`, so the earliest waiting one goes next).
        # File order would let the first entry added win every tick and starve
        # the rest into their max_skips.
        due = list.select { |entry| entry.enabled && entry.due?(now) }
                  .sort_by { |entry| [entry.next_due.to_s, entry.id] }
        return Tick.new(locked: false, outcomes: []) if due.empty?

        # One session listing for the whole tick: a chain walk re-globbing
        # every session per call is the tick's dominant cost.
        index = Index.new(@state_dir)
        updated = file.entries.dup
        # One firing per chain per tick. A second chain entry of the same chain
        # would continue the link the first one just made: that link has no
        # worker lock yet and is not in this tick's index, so the busy check
        # cannot see it, and its prompt would be archived before it ever ran.
        fired_chains = {}
        due.each do |entry|
          position = updated.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
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
          if entry.mode == CHAIN && fired_chains[chain_key(index, entry)]
            reason = "the chain just fired; retry at the next tick"
            updated[position] = skipped(entry, reason) unless dry_run
            outcomes << Outcome.new(id: entry.id, title: entry.title, status: "skipped", detail: reason, entry: entry)
            next
          end
          if dry_run
            fired_chains[chain_key(index, entry)] = true if entry.mode == CHAIN
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
          fired_chains[chain_key(index, entry)] = true if entry.mode == CHAIN
        end
        write(file: file.with(entries: updated)) unless dry_run
      end

      pending.each { |entry| outcomes << fire_and_record(entry, index) }
      Tick.new(locked: false, outcomes: outcomes)
    end

    # Fire one entry now, whatever its next_due says (`chi schedule run-now`).
    # A refusal is recorded exactly as a tick records one — the counters move,
    # and max_skips or max_failures can disable a schedule that can never run.
    # `due_was` is not involved: run-now is not a scheduled occurrence, so
    # there is no clock to put back and next_due stays where it was.
    # @return [Outcome]
    def run_now(id_or_name)
      entry = lookup(id_or_name)
      return Outcome.new(id: id_or_name.to_s, status: "failed", detail: "no such schedule") if entry.nil?

      index = Index.new(@state_dir)
      verdict = check(entry, index)
      if verdict
        kind, reason = verdict
        status = kind == :skip ? "skipped" : "failed"
        record_refusal(entry, status, reason)
        return Outcome.new(id: entry.id, title: entry.title, status: status, detail: reason, entry: entry)
      end

      fire_and_record(advance(entry, @clock.call), index)
    end

    # Minutes between the hub's ticks when schedule.auto_tick is on.
    def self.tick_interval_minutes
      value = Config.get("schedule.tick_interval_minutes").to_i
      value.positive? ? value : 5
    end

    # A recurrence from the CLI's flags or the tool's arguments. Blank strings
    # (what a model sends for the fields it did not use) count as absent.
    # @return [Hash] {kind:, ...}
    # @raise [Usage] none or more than one kind given, or an interval that is
    #   not a positive amount of time
    def self.recurrence(every: nil, weekday: nil, time: nil, date: nil)
      every = nil if every.to_s.strip.empty?
      weekday = nil if weekday.to_s.strip.empty?
      time = nil if time.to_s.strip.empty?
      date = nil if date.to_s.strip.empty?

      kinds = [every, weekday, date].compact
      raise Usage, "a schedule needs one of every, weekday or date" if kinds.empty?
      raise Usage, "give one of every, weekday or date, not more" if kinds.size > 1

      if every
        raise Usage, "time is only for a weekday schedule" if time && !weekday

        interval = every.to_s.strip
        raise Usage, "every needs an interval like 30m, 2h or 1d, got #{every}" unless interval.match?(/\A\d+[smhd]?\z/)

        seconds = interval_seconds(interval)
        raise Usage, "every must be at least 1s, got #{every}" if seconds.nil? || seconds.zero?

        { kind: "every", interval: interval }
      elsif weekday
        raise Usage, "weekday needs time HH:MM" if time.nil?

        day = weekday.to_s.strip
        raise Usage, "weekday must be 1 (Mon) to 7 (Sun), got #{weekday}" unless day.match?(/\A[1-7]\z/)

        { kind: "weekday", weekday: day.to_i, time: time.to_s.strip }
      else
        { kind: "date", at: local_moment(*parse_local(date)).utc.iso8601 }
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

      # A chain's root: +id+ back through `continues` until a link with no
      # predecessor. Entries of one chain share this root whichever link each
      # of them was added against.
      def root(id)
        seen = [id]
        while (previous = @by_id[seen.last]&.continues) && !seen.include?(previous)
          seen << previous
        end
        seen.last
      end
    end

    # The length of an interval in seconds; nil for something that is not an
    # interval, and nil for zero so a `0m` schedule can never fire every tick.
    def self.interval_seconds(interval)
      match = interval.to_s.strip.match(/\A(\d+)(s|m|h|d)?\z/)
      return nil unless match

      seconds = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400, nil => 60 }[match[2]] * match[1].to_i
      seconds.positive? ? seconds : nil
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

    # @param strict [Boolean] a file that is not readable JSON raises rather
    #   than reading as empty: a write starting from an empty list would rewrite
    #   the file and lose every schedule on it. Listing stays lenient.
    def read(strict: false)
      return FORMAT.read({}, collection: "schedules") unless File.exist?(path)

      file = FORMAT.read(JSON.parse(File.read(path)), collection: "schedules")
      file.with(entries: file.entries.map do |record|
        if record.readable?
          Entry.from_record(record)
        else
          Log.warn(:worker, "schedule_entry_unreadable",
                   id: record.raw.is_a?(Hash) ? record.raw["id"] : nil,
                   missing: record.missing.map(&:to_s))
          record
        end
      end)
    rescue JSON::ParserError, StateFormat::InvalidDocument => e
      Log.warn(:worker, "store_unreadable", error: e.class.name, msg: e.message)
      raise Corrupt, "#{path} is not readable JSON (#{e.message}): fix or remove it before changing schedules" if strict

      FORMAT.read({}, collection: "schedules")
    end

    def write(file:)
      FileUtils.mkdir_p(@store_dir)
      FileUtils.mkdir_p(@state_dir)
      body = FORMAT.write(file, collection: "schedules", updated_at: Time.now.utc.iso8601)
      AtomicFile.write(path, "#{JSON.pretty_generate(body)}\n")
    end

    # Every write of the file is a read-modify-write under the lock.
    def write_under_lock
      FileUtils.mkdir_p(@store_dir)
      FileUtils.mkdir_p(@state_dir)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        file = read(strict: true)
        yield(file)
        write(file: file)
      end
    end

    # The same resolution as #lookup — an id, a unique prefix, or a title, and
    # an ambiguous one raises Usage rather than taking the first match.
    def change(id_or_name, enabled: nil, delete: false)
      entry = lookup(id_or_name)
      return nil if entry.nil?

      write_under_lock do |file|
        position = file.entries.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
        next if position.nil?

        if delete
          file.entries[position] = nil
          file.entries.compact!
        else
          file.entries[position] = entry.with(enabled: enabled, last_result: enabled ? "enabled" : "disabled")
        end
      end
      entry
    end

    # +name+ is what the caller's flag is called, so a bad value says which one.
    def int_or_default(value, key, fallback, min:, name: key.split(".").last)
      unless value.nil? || value.to_s.strip.empty?
        raise Usage, "#{name} must be a number, got #{value.inspect}" unless value.to_s.strip.match?(/\A-?\d+\z/)

        return [value.to_i, min].max
      end

      configured = Config.get(key)
      configured.to_s.strip.match?(/\A-?\d+\z/) ? [configured.to_i, min].max : fallback
    end

    def positive_config(key, fallback)
      value = Config.get(key).to_i
      value.positive? ? value : fallback
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
    # +from+ (today counts when the time is still ahead). cwday, not wday:
    # Ruby's wday is 0 for Sunday while the CLI, the tool and the docs say
    # 7=Sun. Built with Time.local, never now + 86400*n: a schedule at 09:00
    # keeps its wall clock across a DST change, while `every 1d` drifts an hour
    # across the fold (docs/scheduling.md says so and points at --weekday for a
    # time of day). Eight days is more than a week, so a valid weekday always
    # has an occurrence: reaching the raise is a bug, and a silent fallback
    # would turn a weekly schedule into a daily one.
    def weekday_moment(weekday, time, from:)
      hour, minute = Schedules.parse_clock(time)
      start = from.to_date
      8.times do |step|
        date = start + step
        candidate = Schedules.local_moment(date.year, date.month, date.day, hour, minute)
        next if candidate <= from || candidate.to_date.cwday != weekday

        return candidate
      end
      raise Usage, "no #{WEEKDAYS[weekday]} occurs within 8 days of #{from}"
    end

    # catch_up: none fires only when the tick arrives at the moment. "Late"
    # means a whole cycle, not a late tick: an entry is missed only when the
    # occurrence after the one it missed is past as well, which is what the file
    # looks like when the machine was asleep across the interval. A Mon 09:00
    # schedule ticked at 09:20 is simply late and fires; one first seen the
    # following Monday is missed and moves to the Monday after. A `date` one-off
    # has no next occurrence to compare with, so it is never missed: it fires
    # late, once.
    def late?(entry, now)
      return false if entry.recurrence[:kind] == "date"

      # due? has already accepted next_due, so it parses.
      next_due_for(entry.recurrence, from: Time.iso8601(entry.next_due.to_s)) <= now
    end

    # The clock moves to the next occurrence. A `date` one-off has none, so it
    # is disabled — `late?` never sends a one-off here, but a spent `date` entry
    # arriving from an older file is still spent.
    def reschedule(entry, now)
      if entry.recurrence[:kind] == "date"
        entry.with(next_due: nil, last_result: "missed", firing_since: nil, enabled: false)
      else
        entry.with(next_due: next_due_for(entry.recurrence, from: now).utc.iso8601, last_result: "missed", firing_since: nil)
      end
    end

    # The clock advances and the entry is marked firing before the action: a
    # tick killed mid-continue cannot fire the same entry twice. The occurrence
    # it tried is kept as due_was, so a skip or a failure puts it back: the
    # schedule was not late, it just could not run now. A `date` one-off has no
    # next occurrence, so advancing it spends it — the entry is disabled until
    # a skip or a failure puts its moment back.
    def advance(entry, now)
      one_off = entry.recurrence[:kind] == "date"
      entry.with(due_was: entry.next_due,
                 next_due: one_off ? nil : next_due_for(entry.recurrence, from: now).utc.iso8601,
                 last_fired: now.utc.iso8601, firing_since: now.utc.iso8601, last_result: nil,
                 enabled: one_off ? false : entry.enabled)
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

    # The session the entry would act on: its head, followed through every
    # continue made since it was last written — a chain firing's new link or a
    # human `chi send --continues`/`chi resume` (SessionChain.latest, the same
    # walk SessionContinue.run does for `last:`). Both modes use the walk: a
    # chain continues that link, a same-mode entry queues a turn in it. The
    # anchor alone is not enough for either: the first continue archives it, so
    # a same-mode entry read literally would fail "archived" from then on, and
    # the chain would continue a link that is no longer the end. The anchor is
    # the fallback when the head is gone (pruned or deleted by hand): the walk
    # from it still finds the chain's end.
    def target_of(entry, index)
      head = index.latest(index.gone?(entry.head) ? entry.anchor : entry.head)
      if index.gone?(head)
        return [nil, entry.mode == CHAIN ? "the chain is gone" : "the session it was made against is gone"]
      end

      return [nil, "archived"] if index.archived?(head)

      [head, nil]
    end

    # Which chain an entry belongs to, for the one-firing-per-chain-per-tick
    # guard: the root of the chain its resolved target is in. Every entry of a
    # chain has the same root, whichever link it was added against.
    def chain_key(index, entry)
      target, _reason = target_of(entry, index)
      index.root(target)
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
      entry.mode == CHAIN ? fire_chain(entry, index) : fire_same(entry, index)
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
      # a continue a human made between here and its lock. The link's first
      # turn is the schedule's (its origin), as a same-mode firing's is.
      link = SessionContinue.run("last:#{head}", prompt: entry.prompt, state_dir: @state_dir,
                                                 client_id: ClientId.schedule(entry.id))
      Outcome.new(id: entry.id, title: entry.title, status: "fired", detail: "new link #{link.id[0, 8]}",
                  entry: entry.with(head: link.id))
    rescue SessionContinue::Refused => e
      classify(entry, e.reason, e.message)
    rescue SessionManager::ArchiveRefused => e
      classify(entry, e.reason, e.message)
    end

    def fire_same(entry, index)
      target, reason = target_of(entry, index)
      return Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: reason, entry: entry) if target.nil?

      # Checked again, against the files: a continue made between the tick's
      # listing and this moment archives the target it just resolved to.
      dir = Session.session_dir(target, state_dir: @state_dir)
      return Outcome.new(id: entry.id, title: entry.title, status: "failed", detail: "archived", entry: entry) if ArchiveStore.archived?(dir)

      result = SessionManager.deliver_turn(target, prompt: entry.prompt,
                                          client_id: ClientId.schedule(entry.id),
                                          delivery: Delivery::QUEUE, state_dir: @state_dir)
      if result.accepted?
        # The head follows the turn: the next tick resolves from the link this
        # one fired into, so the walk survives a link deleted in between.
        Outcome.new(id: entry.id, title: entry.title, status: "fired", detail: "queued a turn", entry: entry.with(head: target))
      else
        Outcome.new(id: entry.id, title: entry.title, status: "failed",
                    detail: "the turn was not accepted (#{result.status}: #{result.error || result.detail})", entry: entry)
      end
    end

    def classify(entry, reason, message)
      status = SKIP_REASONS.include?(reason.to_s) ? "skipped" : "failed"
      Outcome.new(id: entry.id, title: entry.title, status: status, detail: message, entry: entry)
    end

    # A run-now refused before anything was tried: the same counters a tick
    # moves for a skip or a failure. `due_was` is untouched — run-now is not a
    # scheduled occurrence, so there is no occurrence to put the clock back to.
    def record_refusal(entry, status, reason)
      write_under_lock do |file|
        position = file.entries.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
        next if position.nil?

        stored = file.entries[position]
        file.entries[position] = status == "skipped" ? skipped(stored, reason) : failed(stored, reason)
      end
    end

    # The result goes back under the lock before any pruning, so a prune that
    # raises midway cannot lose the new head.
    def record(entry, outcome)
      write_under_lock do |file|
        position = file.entries.index { |candidate| candidate.is_a?(Entry) && candidate.id == entry.id }
        next if position.nil?

        stored = file.entries[position]
        updated = if outcome.status == "fired"
                    # Any success clears the skip and failure counters: twelve
                    # skips spread over months do not kill a healthy schedule.
                    # A `date` schedule is a one-off: `advance` already left it
                    # with no next_due and disabled, and a firing keeps it so.
                    stored.with(head: outcome.entry.head, last_result: outcome.detail, firing_since: nil,
                                failures: 0, skips: 0, last_fired: @clock.call.utc.iso8601)
                  elsif outcome.status == "skipped"
                    skipped(stored, outcome.detail).with(firing_since: nil)
                  else
                    failed(stored, outcome.detail)
                  end

        # A skip or a failure is "not now", not "late": the occurrence the tick
        # tried comes back, so the next tick tries it again. max_skips and
        # max_failures bound how often that happens.
        updated = updated.with(next_due: stored.due_was) if outcome.status != "fired" && !stored.due_was.nil?
        file.entries[position] = updated
      end
    end

    # The links behind the kept window, with the delegates that hung under
    # them: archiving a link archives its descendants, and archived sessions
    # are outside the retention sweep, so the delegate pile is the bulk of the
    # archived count. Oldest link first, and within a link its children first
    # (deepest first) and the link last. The walk stops at a link that is not
    # archived, one whose subtree has a live worker, or one with a descendant
    # still unarchived: nothing is deleted in that case, and the next firing
    # retries (a schedule failure it is not). The anchor is never pruned:
    # `last:<anchor>` must keep resolving, and it is the id the user remembers.
    def prune(entry, index)
      links = []
      id = entry.head
      seen = []
      while id && !seen.include?(id)
        seen << id
        links << id
        # The walk stops at the anchor: the links before it are the user's own
        # history, made before this schedule existed, and the anchor itself is
        # the id `last:<anchor>` and the user remember.
        break if id == entry.anchor

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

        descendants = SessionManager.descendant_ids(link, @state_dir)
        # The whole subtree must be ready: a live worker anywhere in it, or a
        # link's descendant that is not archived, stops the walk here rather
        # than half-deleting a tree.
        owned = [link, *descendants].select { |sid| SessionManager.session_owner(sid, state_dir: @state_dir) }
        unless owned.empty?
          Log.warn(:worker, "prune_waiting", sid: link, id: entry.id, owned: owned.map { |sid| sid[0, 8] })
          break
        end

        open = descendants.reject { |sid| ArchiveStore.archived?(Session.session_dir(sid, state_dir: @state_dir)) }
        unless open.empty?
          Log.warn(:worker, "prune_open_children", sid: link, id: entry.id, open: open.map { |sid| sid[0, 8] })
          break
        end

        # Children first (deepest first), the link last: if a delete is
        # refused partway, nothing above it has gone, so the next firing
        # retries the same set instead of leaving children under a link that
        # is already deleted.
        (descendants.reverse + [link]).each do |sid|
          SessionManager.delete_session(sid, state_dir: @state_dir)
        end
        Log.info(:worker, "pruned_link", sid: link, id: entry.id, links: descendants.size + 1)
      end
    rescue SessionManager::DeleteRefused => e
      Log.warn(:worker, "prune_stopped", sid: e.session_id, id: entry.id, msg: e.message)
    rescue Session::NotFound => e
      Log.warn(:worker, "prune_missing", id: entry.id, msg: e.message)
    end
  end
end
