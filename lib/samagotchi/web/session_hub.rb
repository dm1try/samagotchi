# frozen_string_literal: true

require "json"
require "monitor"
require "time"

require_relative "../session"
require_relative "../session_manager"
require_relative "../session_continue"
require_relative "../schedules"
require_relative "../bridge_client"
require_relative "../worker_link"
require_relative "../config"
require_relative "../log"
require_relative "../installed_versions"
require_relative "../version"
require_relative "session_summary"

module Samagotchi
  module Web
    # chi web's one in-memory projection of the session list, fed by a cheap
    # watcher over the state dir, pushed to every open tab (GET /api/events).
    # Files stay the source of truth; workers and the Bridge don't know it.
    #
    # Every session-JSON writer goes tmp + rename, and rename-into-dir and
    # unlink bump the parent dir's mtime, so one stat of the state dir says
    # "some session file changed" and one stat of `<id>/` says "recap.json
    # or bridge.json appeared, changed or went". Nothing in-place is
    # watched: owner.lock is read by the owner probes.
    #
    # #scan does one pass and is driven by the tick thread (#start) or by a
    # spec. Scan, #touch, the projection and the deliveries all run under
    # one Monitor, and a subscriber is added and its snapshot taken as one
    # step under it, so no stale upsert can follow a fresh snapshot.
    class SessionHub
      SCAN_INTERVAL = 1.0
      # What an info route says about updates when there is no hub at all:
      # this chi's version, and nothing known of the rest. The one place this
      # is written (Web::App#handle_info and the remote info route).
      HUBLESS_STATE = { version: Samagotchi::VERSION, installed: nil, available: nil, update_blocked: nil,
                        auto: "off", restart: "idle", auto_offers: nil }.freeze

      # The flock leaves no file trace when its holder dies, so owners are
      # probed: every tick for the sessions the projection believes owned
      # (a handful; OwnerLock.owner is open + LOCK_SH|LOCK_NB + close), and
      # all sessions this often (a one-shot or an older chi's REPL that
      # opened an old session without saving it has no file signal until its first save).
      FULL_PROBE_INTERVAL = 10.0
      SCHEDULE_TICK_STOP_WAIT = 5.0
      # The pages folder's stamp before the first look (nil is a folder that isn't there).
      UNSEEN = Object.new.freeze
      SWEEP_STOP_WAIT = 5.0

      # What a subscriber gets: `session` with {session: summary} for an
      # upsert, `session_gone` with {id:} for a removal, `chi` with
      #   the #chi_state fields when chi version state changes, `chi_notice`
      #   (#publish_notice) and `schedule_disabled` (#publish_disabled: any
      #   ticker's budget turn-off) for the Push::Notifier, and `pages` (no data)
      #   when the pages' scripts folder changed (#check_pages). seq is
      #   monotonic per hub, for the log's sake: there is no replay.
      Event = Struct.new(:type, :seq, :data, keyword_init: true)

      # The projection's entry: the summary the page sees, the parsed
      # (messages-less) Session it was built from, and the stamps that say
      # whether anything changed: the file's [mtime, size], the session
      # dir's mtime, and the live stamp {pid, kind, bridge_started_at} so
      # a change of worker is a change even when `owner` reads the same.
      Entry = Struct.new(:session, :summary, :stamp, :dir_stamp, :owner, :live, keyword_init: true)

      # Returned by #subscribe.
      class Subscription
        def initialize(sink, hub)
          @sink = sink
          @hub = hub
        end

        def call(event)
          @sink.call(event)
        end

        def unsubscribe
          @hub.unsubscribe(self)
        end
      end

      # @param state_dir [String] the sessions dir (Session.default_state_dir)
      # @param manager [#session_owner, #retention_sweep_if_due] SessionManager,
      #   or a stand-in
      # @param now [#call] a monotonic clock in seconds (specs drive it)
      # @param installed_versions [#newest] what is installed (InstalledVersions)
      # @param update_auto [String] update.auto, said in the chi state (the page's wording)
      # @param update_restart [String] update.restart, said beside it (whether
      #   a newer installed chi restarts by itself: no Restart toast)
      # @param pages_dir [String, nil] the pages' scripts folder
      #   (Pages.scripts_dir, which Server.start passes), watched for the
      #   `pages` event; nil watches none
      def initialize(state_dir:, manager: SessionManager, now: nil, scan_interval: SCAN_INTERVAL,
                     full_probe_interval: FULL_PROBE_INTERVAL, installed_versions: InstalledVersions.new,
                     update_auto: Config.get("update.auto"), update_restart: Config.get("update.restart"),
                     pages_dir: nil)
        @state_dir = state_dir
        @pages_dir = pages_dir
        @pages_stamp = UNSEEN
        @update_auto = update_auto
        @update_restart = update_restart
        @installed_versions = installed_versions
        @installed = nil
        @available = nil
        @update_blocked = nil
        @auto_offers = nil
        @update_state = nil
        @manager = manager
        @now = now || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
        @scan_interval = scan_interval
        @full_probe_interval = full_probe_interval
        @monitor = Monitor.new
        @sessions = {}      # id → Entry
        @subscribers = []
        @seq = 0
        @dir_mtime = nil    # the state dir's mtime at the last glob
        @root_cache = {}    # folder → project root, for sessions saved before project_root
        @next_full_probe = nil
        @next_schedule_tick = nil
        @next_notice_claim = nil
        @schedule_tick_in_flight = false
        @schedule_tick_thread = nil
        @sweep_thread = nil
        @wakeup = Queue.new # stop wakes the tick thread out of its sleep
        @thread = nil
        @stopped = false
      end

      # Spawn the tick thread (idempotent). Logs nothing: Server.start's
      # start and stop lines are the web log's.
      def start
        return self if @thread&.alive?

        @stopped = false
        @thread = Thread.new { run_loop }
        self
      end

      # End the tick thread (idempotent); the event loops see #stopped?.
      def stop
        @stopped = true
        @wakeup << :stop
        thread = @thread
        @thread = nil
        thread&.join(@scan_interval + 1.0)
        drain_schedule_tick(timeout: SCHEDULE_TICK_STOP_WAIT)
        sweep_thread = @monitor.synchronize { @sweep_thread }
        sweep_thread&.join(SWEEP_STOP_WAIT)
        nil
      end

      def stopped?
        @stopped
      end

      # One pass: what changed on disk since the last one, emitted. Every
      # +full_probe_interval+ it also probes every session's owner and
      # gives the retention sweep its chance (it used to run on
      # GET /api/sessions, which the page no longer calls).
      def scan(tick: true)
        full = @monitor.synchronize do
          full = full_probe_due?
          SessionContinue.repair_interrupted(state_dir: @state_dir)
          scan_files
          check_pages
          @sessions.each_key { |id| refresh(id, probe: full) }
          if full
            check_installed
          end
          full
        end
        sweep_if_due if full
        # Outside the projection's lock: a firing can wait for a recap.
        schedule_tick if tick
        nil
      end

      # Launch at most one sweep; neither projection readers nor requests
      # wait for its per-session task stops.
      def sweep_if_due
        @monitor.synchronize do
          return if @stopped || @sweep_thread&.alive?

          @sweep_thread = Thread.new { sweep }
        end
        nil
      end

      # The newest installed chi as of the last full probe (nil: unknown).
      def installed
        @monitor.synchronize { @installed }
      end

      # Look at what is installed now, not at the next full probe (after an
      # install): a change is the usual `chi` event.
      # @return [String, nil] the newest installed chi
      def refresh_installed
        @monitor.synchronize do
          check_installed
          @installed
        end
      end

      # An accepted answer ends the wait before the worker has saved its
      # resumed session. Clear that question from the projection now.
      def resolve_question(id, question_id:)
        return nil unless Session.valid_id?(id)

        @monitor.synchronize do
          entry = @sessions[id]
          pending = entry&.summary&.dig(:pending_question)
          next unless pending && pending[:id].to_s == question_id.to_s

          entry.summary = entry.summary.merge(pending_question: nil)
          emit("session", session: entry.summary)
        end
        nil
      end

      # The complete chi version state used by event snapshots and info routes.
      def chi_state
        @monitor.synchronize do
          { version: VERSION, installed: @installed, available: @available, update_blocked: @update_blocked,
            auto: @update_auto, restart: @update_restart, auto_offers: @auto_offers }
        end
      end

      # Publish the update check's answer without holding the Monitor while it
      # fetches releases. A newly selected release may carry a one-shot push hint.
      def update_available(available:, blocked:, notify: false)
        @monitor.synchronize do
          changed = available != @available || blocked != @update_blocked
          @available = available
          @update_blocked = blocked
          emit("chi", chi_state.merge(notify ? { update_notice: true } : {})) if changed || notify
        end
        nil
      end

      # AutoUpdate won't (or hasn't, for long) restart onto +version+ by itself:
      # the page offers the restarts for it, in spite of update.auto. In memory:
      # AutoUpdate says it again after a chi web restart.
      def auto_offer_restart(version)
        @monitor.synchronize do
          next if @auto_offers == version

          @auto_offers = version
          emit("chi", chi_state)
        end
        nil
      end

      # Publish the owner-triggered update's progress or result for current
      # tabs, and retain the latest state for a reconnect's snapshot.
      def publish_update(state:, rows:, progress: nil, operation: nil, version: nil, auto: false)
        @monitor.synchronize do
          @update_state = { state: state, rows: rows }
          @update_state[:auto] = true if auto
          @update_state[:operation] = operation unless operation.nil?
          @update_state[:version] = version unless version.nil?
          @update_state[:progress] = progress unless progress.nil?
          emit("chi_update", @update_state)
        end
        nil
      end

      def update_state
        @monitor.synchronize { @update_state&.dup }
      end

      # What the automatic update (AutoUpdate) has to tell the owner's phone:
      # a `chi_notice` event for the Push::Notifier, not for the page (the
      # `chi_update` frames are the page's), and not kept for a snapshot.
      # @param kind [String] installed, updated or failed
      # @param version [String] the release it is about
      # @param notes [Hash] detail:, kept:, merged: (counts of edited files that
      #   stayed behind and that took the update), restarted:, left:
      def publish_notice(kind:, version:, **notes)
        @monitor.synchronize { emit("chi_notice", { kind: kind, version: version, **notes }) }
        nil
      end

      # Rescan one session now (its file, its folder, its owner), for the
      # page's own actions: no waiting for the next tick.
      def touch(id)
        return nil unless Session.valid_id?(id)

        @monitor.synchronize do
          path = Session.session_file(id, state_dir: @state_dir)
          if File.file?(path)
            @sessions[id] ||= Entry.new
            refresh(id, probe: true)
          elsif @sessions.key?(id)
            drop(id)
          end
        end
        nil
      end

      # The projection as the list route answers it: sorted, and only
      # +project_root+'s sessions when one is given (nil: every session, as
      # outside a repo).
      # @return [Array<Hash>] summaries
      def snapshot(project_root: nil, sort: "updated_at", order: "desc")
        @monitor.synchronize do
          entries = @sessions.values.reject { |e| e.summary.nil? }
          entries = entries.select { |e| e.summary[:project_root] == project_root } if project_root
          key = sort.to_s == "created_at" ? :created_at : :updated_at
          sorted = entries.sort_by { |e| sort_time(e.summary[key]) }
          sorted.reverse! unless order.to_s == "asc"
          sorted.map(&:summary)
        end
      end

      # A session's folder as the projection holds it (its file's, read at
      # the last scan or touch): what a live read that loads no session
      # file checks refs against. nil for a session the hub hasn't seen.
      # @return [String, nil]
      def working_directory(id)
        @monitor.synchronize { @sessions[id]&.session&.working_directory }
      end

      # Register a sink (#call(event)). With +snapshot:+ the current
      # projection comes back with the handle, taken in the same step, so
      # every event after it is newer than it.
      # @return [Subscription, (Subscription, Array<Hash>)]
      def subscribe(sink, snapshot: false, project_root: nil)
        @monitor.synchronize do
          handle = Subscription.new(sink, self)
          @subscribers << handle
          return handle unless snapshot

          [handle, self.snapshot(project_root: project_root)]
        end
      end

      def unsubscribe(handle)
        @monitor.synchronize { !@subscribers.delete(handle).nil? }
      end

      # chi web can be the scheduler when the user opts in (schedule.auto_tick):
      # the same tick cron runs, gated by schedule.tick_interval_minutes and
      # sharing schedules.lock, so cron and the hub never both fire. The scan
      # loop only launches one tick at a time; it does not wait for a firing.
      # The disabled notices any ticker left are pushed from here too, with
      # auto_tick off as well (#claim_disabled_if_due). Only the scan(tick:
      # true) path gets here: server.rb's seeding scan(tick: false) runs before
      # the Notifier subscribes, and a notice claimed then would reach no one.
      # @return [Thread, nil] the Thread it started, or nil when it started none.
      def schedule_tick
        claim_disabled_if_due
        return nil unless Config.get("schedule.auto_tick")

        now = @now.call
        @monitor.synchronize do
          if @schedule_tick_in_flight || (@next_schedule_tick && now < @next_schedule_tick)
            nil
          else
            @next_schedule_tick = now + (Samagotchi::Schedules.tick_interval_minutes * 60)
            @schedule_tick_in_flight = true
            @schedule_tick_thread = Thread.new { run_schedule_tick }
          end
        end
      rescue StandardError => e
        @monitor.synchronize do
          if @schedule_tick_in_flight && @schedule_tick_thread.nil?
            @schedule_tick_in_flight = false
            @next_schedule_tick = nil
          end
        end
        Log.warn(:web, "schedule_tick_failed", error: e.class.name, msg: e.message)
        nil
      end

      # The tick's body on the caller's thread (the specs call it directly;
      # #schedule_tick runs it on its own thread).
      def run_schedule_tick
        schedules = Samagotchi::Schedules.new(state_dir: @state_dir)
        # Stopping kills a condition's CMD (its process group) and runs no more.
        schedules.tick(now: Time.now, cancelled: -> { stopped? })
        # Right after the tick, so a turn-off of this tick is pushed now.
        retry_notices_next_scan if publish_disabled(schedules)
      rescue StandardError => e
        Log.warn(:web, "schedule_tick_failed", error: e.class.name, msg: e.message)
      ensure
        @monitor.synchronize do
          @schedule_tick_in_flight = false
          @schedule_tick_thread = nil
        end
      end

      # Whether a schedule tick is at work (started, not finished).
      def schedule_tick_running?
        @monitor.synchronize { @schedule_tick_in_flight }
      end

      # Waits for a running schedule tick to finish (it does not start one).
      # @return [Boolean] true once no tick is running, else false.
      def drain_schedule_tick(timeout:)
        thread = @monitor.synchronize { @schedule_tick_thread }
        thread&.join(timeout)
        @monitor.synchronize { !@schedule_tick_in_flight }
      end

      private

      def run_loop
        until @stopped
          begin
            scan
          rescue StandardError => e
            Log.warn(:web, "hub_scan_failed", error: e.class.name, msg: e.message)
          end
          @wakeup.pop(timeout: @scan_interval)
        end
      end

      def full_probe_due?
        now = @now.call
        return false if @next_full_probe && now < @next_full_probe

        @next_full_probe = now + @full_probe_interval
        true
      end

      def sweep
        @manager.retention_sweep_if_due(state_dir: @state_dir)
      rescue StandardError => e
        Log.warn(:web, "retention_sweep_failed", error: e.class.name, msg: e.message)
      end

      # Once per schedule.tick_interval_minutes: a lock-free read of
      # schedules.json (Schedules#claim_disabled_notices), so a cron tick's or
      # a run-now's turn-off reaches the phone within one interval. A claim
      # that found notices but the lock held (a tick at work) is tried again
      # at the next scan, not a whole interval later.
      def claim_disabled_if_due
        now = @now.call
        due = @monitor.synchronize do
          next false if @next_notice_claim && now < @next_notice_claim

          @next_notice_claim = now + (Samagotchi::Schedules.tick_interval_minutes * 60)
          true
        end
        retry_notices_next_scan if due && publish_disabled(Samagotchi::Schedules.new(state_dir: @state_dir))
      end

      def retry_notices_next_scan
        @monitor.synchronize { @next_notice_claim = nil }
      end

      # A recurring schedule a ticker turned off by its budget (any ticker: the
      # notice is in schedules.json, Schedules#claim_disabled_notices): one
      # `schedule_disabled` event each, for the Push::Notifier (the page has no
      # listener), emitted the way #publish_notice does, after the claim let
      # the lock go. +at+ is the disabling tick's time; +session_id+ is the
      # session the schedule acts on. The claim clears each notice before it
      # is emitted: the Notifier's dedupe is per process, so two chi webs on
      # one state dir would otherwise both push it.
      # @return [Boolean] true: there were notices but the lock was held
      def publish_disabled(schedules)
        held = false
        schedules.claim_disabled_notices(now: Time.now, on_lock_held: -> { held = true }).each do |data|
          @monitor.synchronize { emit("schedule_disabled", data) }
        rescue StandardError => e
          Log.warn(:web, "schedule_disabled_failed", id: data[:id], error: e.class.name, msg: e.message)
        end
        held
      rescue StandardError => e
        Log.warn(:web, "schedule_notices_failed", error: e.class.name, msg: e.message)
        false
      end

      # A change (the first look too, unless it finds nothing) is a `chi`
      # event: chi web's terminal line and the open tabs hear it.
      def check_installed
        newest = @installed_versions.newest
        return if newest == @installed

        @installed = newest
        emit("chi", chi_state)
        refresh_worker_compat
      rescue StandardError => e
        Log.warn(:web, "installed_check_failed", error: e.class.name, msg: e.message)
      end

      def refresh_worker_compat
        # An installed-version change can stale a worker without changing its files.
        @sessions.each_value do |entry|
          summary = entry.summary
          next unless summary&.dig(:worker_version)

          compatibility = Compat.verdict(worker_version: summary[:worker_version], version: @installed || VERSION).to_s
          next if summary[:worker_compat] == compatibility

          entry.summary = summary.merge(worker_compat: compatibility)
          emit("session", session: entry.summary)
        end
      end

      # The pages' scripts folder: one stat a tick. Creating, renaming in or
      # removing a script changes its mtime (a run doesn't: its output is
      # under the state dir), and the page reads GET /api/pages again on the
      # `pages` event. The first look only stores the stamp; a folder that
      # appears or goes is a change.
      def check_pages
        return unless @pages_dir

        stamp = dir_mtime(@pages_dir)
        changed = !@pages_stamp.equal?(UNSEEN) && stamp != @pages_stamp
        @pages_stamp = stamp
        emit("pages", {}) if changed
      end

      # The state dir's files: a new id is parsed and emitted, an id gone
      # from disk is dropped, a changed file is re-parsed. Skipped when the
      # dir's mtime says nothing was renamed in or unlinked since.
      def scan_files
        dir_stat = begin
          File.stat(@state_dir)
        rescue SystemCallError
          nil
        end
        if dir_stat.nil?
          @sessions.keys.each { |id| drop(id) }
          @dir_mtime = nil
          return
        end
        return if dir_stat.mtime == @dir_mtime

        @dir_mtime = dir_stat.mtime
        on_disk = Dir.glob(File.join(@state_dir, "*#{SessionPaths::FILE_EXT}")).to_h do |path|
          [File.basename(path, SessionPaths::FILE_EXT), path]
        end.select { |id, _| Session.valid_id?(id) }
        (@sessions.keys - on_disk.keys).each { |id| drop(id) }
        on_disk.each_key { |id| @sessions[id] ||= Entry.new }
      end

      # Bring one entry up to date with its file, its folder and its owner;
      # emit when the page would see a difference. The owner is probed when
      # asked (+probe+), when the entry believes it has one (to see it go),
      # and when its folder changed (a new owner.lock, a bridge.json).
      def refresh(id, probe: false)
        entry = @sessions[id]
        path = Session.session_file(id, state_dir: @state_dir)
        stat = begin
          File.stat(path)
        rescue SystemCallError
          nil
        end
        return drop(id) if stat.nil?

        stamp = [stat.mtime, stat.size]
        changed = false
        dir = Session.session_dir(id, state_dir: @state_dir)
        dir_stamp = dir_mtime(dir)
        # The folder changing re-reads the file too: a stop is a marker file
        # there (Session::STOPPED_FILE), not a change to the session file.
        if stamp != entry.stamp || dir_stamp != entry.dir_stamp
          session = Session.summary_from_file(path)
          # Corrupt, or missing a field: not a session, as Session.list has it.
          # A `chi scratch` session is never shown.
          return drop(id) if session.nil? || session.scratch

          # Looked up once per parse (a git call for a session saved before
          # the field), never per tick.
          session.project_root = session.project_root(cache: @root_cache)
          entry.session = session
          entry.stamp = stamp
          changed = true
        end
        if dir_stamp != entry.dir_stamp
          entry.dir_stamp = dir_stamp
          changed = true
        end
        owner = probe || changed || entry.owner ? owner_of(id) : entry.owner
        live = live_stamp(owner, dir)
        live_changed = live != entry.live
        return unless changed || live_changed

        entry.owner = owner
        entry.live = live
        summary = SessionSummary.build(entry.session, owner: owner, session_dir: dir, registry: hub_registry,
                                       compat_version: @installed || VERSION)
        # A new worker (pid) or a new Bridge for the same session is an
        # event for the page even when the summary reads the same: it
        # reconnects its stream on it.
        return if summary == entry.summary && !live_changed

        entry.summary = summary
        emit("session", session: summary)
      end

      # The registry kept across scans (HostRegistry.current, built again
      # when config.yml's hosts: changed): every session's ctx_pct may need
      # its llm_context budget resolved, and the registry's config read is
      # what would otherwise repeat per scan and per session; a host added
      # or a window changed while chi web runs is picked up on the next
      # refresh of a card.
      def hub_registry = HostRegistry.current

      def drop(id)
        entry = @sessions.delete(id)
        emit("session_gone", id: id) if entry&.summary
      end

      def owner_of(id)
        @manager.session_owner(id, state_dir: @state_dir)
      rescue StandardError
        nil
      end

      def dir_mtime(dir)
        File.stat(dir).mtime
      rescue SystemCallError
        nil
      end

      # A change of worker is a change even when `owner` reads "worker"
      # both times: the pid, or the Bridge's start time, tells them apart.
      def live_stamp(owner, dir)
        return nil unless owner

        { pid: owner.pid, kind: owner.kind, bridge_started_at: bridge_started_at(dir, owner) }
      end

      # The Live worker's start (the owner already read is the one the link answers by).
      def bridge_started_at(dir, owner)
        link = WorkerLink.resolve(dir, unlink: false, owner: owner)
        link.live? ? link.started_at : nil
      end

      def emit(type, data)
        @seq += 1
        event = Event.new(type: type, seq: @seq, data: data)
        @subscribers.dup.each do |handle|
          handle.call(event)
        rescue StandardError => e
          Log.warn(:web, "hub_subscriber_failed", error: e.class.name, msg: e.message)
        end
      end

      def sort_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError
        Time.at(0)
      end
    end
  end
end
