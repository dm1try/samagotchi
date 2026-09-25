# frozen_string_literal: true

require "json"
require "monitor"
require "time"

require_relative "../session"
require_relative "../session_manager"
require_relative "../bridge_client"
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
    # watched: the pid file and owner.lock are read by the owner probes.
    #
    # #scan does one pass and is driven by the tick thread (#start) or by a
    # spec. Scan, #touch, the projection and the deliveries all run under
    # one Monitor, and a subscriber is added and its snapshot taken as one
    # step under it, so no stale upsert can follow a fresh snapshot.
    class SessionHub
      SCAN_INTERVAL = 1.0

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
      # @param manager [#session_owner] SessionManager, or a stand-in
      def initialize(state_dir:, manager: SessionManager)
        @state_dir = state_dir
        @manager = manager
        @monitor = Monitor.new
        @sessions = {}      # id → Entry
        @subscribers = []
        @seq = 0
        @dir_mtime = nil    # the state dir's mtime at the last glob
        @root_cache = {}    # folder → project root, for sessions saved before project_root
        @thread = nil
        @stopped = false
      end

      # One pass: what changed on disk since the last one, emitted.
      def scan
        @monitor.synchronize do
          scan_files
          @sessions.each_key { |id| refresh(id) }
        end
        nil
      end

      # Rescan one session now (its file, its folder, its owner), for the
      # page's own actions: no waiting for the next tick.
      def touch(id)
        @monitor.synchronize do
          path = File.join(@state_dir, "#{id}#{Session::FILE_EXT}")
          if File.file?(path)
            @sessions[id] ||= Entry.new
            refresh(id)
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
        end
        (@sessions.keys - on_disk.keys).each { |id| drop(id) }
        on_disk.each_key { |id| @sessions[id] ||= Entry.new }
      end

      # Bring one entry up to date with its file, its folder and its owner;
      # emit when the page would see a difference.
      def refresh(id)
        entry = @sessions[id]
        path = File.join(@state_dir, "#{id}#{Session::FILE_EXT}")
        stat = begin
          File.stat(path)
        rescue SystemCallError
          nil
        end
        return drop(id) if stat.nil?

        stamp = [stat.mtime, stat.size]
        changed = false
        if stamp != entry.stamp
          session = Session.summary_from_file(path)
          # Corrupt, or missing a field: not a session, as Session.list has it.
          return drop(id) if session.nil?

          # Looked up once per parse (a git call for a session saved before
          # the field), never per tick.
          session.project_root = session.project_root(cache: @root_cache)
          entry.session = session
          entry.stamp = stamp
          changed = true
        end
        dir = Session.session_dir(id, state_dir: @state_dir)
        dir_stamp = dir_mtime(dir)
        if dir_stamp != entry.dir_stamp
          entry.dir_stamp = dir_stamp
          changed = true
        end
        owner = owner_of(id)
        live = live_stamp(owner, dir)
        changed ||= live != entry.live
        return unless changed

        entry.owner = owner
        entry.live = live
        summary = SessionSummary.build(entry.session, owner: owner, session_dir: dir)
        return if summary == entry.summary

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

        { pid: owner["pid"], kind: owner["kind"], bridge_started_at: bridge_started_at(dir) }
      end

      def bridge_started_at(dir)
        JSON.parse(File.read(File.join(dir, BridgeClient::SIDECAR_FILE)))["started_at"]
      rescue StandardError
        nil
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
