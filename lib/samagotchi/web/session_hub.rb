# frozen_string_literal: true

require "json"
require "monitor"
require "time"

require_relative "../session"
require_relative "../session_manager"
require_relative "../bridge_client"
require_relative "../worker_sidecar"
require_relative "../log"
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
      # The flock leaves no file trace when its holder dies, so owners are
      # probed: every tick for the sessions the projection believes owned
      # (a handful; OwnerLock.owner is open + LOCK_SH|LOCK_NB + close), and
      # all sessions this often (a plain REPL that opened an old session
      # without saving it has no file signal until its first save).
      FULL_PROBE_INTERVAL = 10.0

      # What a subscriber gets: `session` with {session: summary} for an
      # upsert, `session_gone` with {id:} for a removal. seq is monotonic per
      # hub, for the log's sake: there is no replay.
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
      def initialize(state_dir:, manager: SessionManager, now: nil, scan_interval: SCAN_INTERVAL,
                     full_probe_interval: FULL_PROBE_INTERVAL)
        @state_dir = state_dir
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
        nil
      end

      def stopped?
        @stopped
      end

      # One pass: what changed on disk since the last one, emitted. Every
      # +full_probe_interval+ it also probes every session's owner and
      # gives the retention sweep its chance (it used to run on
      # GET /api/sessions, which the page no longer calls).
      def scan
        @monitor.synchronize do
          full = full_probe_due?
          scan_files
          @sessions.each_key { |id| refresh(id, probe: full) }
          sweep if full
        end
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
        return unless @manager.respond_to?(:retention_sweep_if_due)

        @manager.retention_sweep_if_due(state_dir: @state_dir)
      rescue StandardError
        nil
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
        on_disk = Dir.glob(File.join(@state_dir, "*#{Session::FILE_EXT}")).to_h do |path|
          [File.basename(path, Session::FILE_EXT), path]
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
        summary = SessionSummary.build(entry.session, owner: owner, session_dir: dir)
        # A new worker (pid) or a new Bridge for the same session is an
        # event for the page even when the summary reads the same: it
        # reconnects its stream on it.
        return if summary == entry.summary && !live_changed

        entry.summary = summary
        emit("session", session: summary)
      end

      def drop(id)
        entry = @sessions.delete(id)
        emit("session_gone", id: id) if entry&.summary
      end

      def owner_of(id)
        return nil unless @manager.respond_to?(:session_owner)

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

        { pid: owner.pid, kind: owner.kind, bridge_started_at: bridge_started_at(dir) }
      end

      def bridge_started_at(dir)
        WorkerSidecar.read(dir)&.started_at
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
