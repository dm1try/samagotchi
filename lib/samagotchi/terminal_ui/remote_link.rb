# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require_relative "attach_link"
require_relative "../session_access"
require_relative "../session_access/remote"
require_relative "../session_access/web_bridge_client"
require_relative "../children_status"
require_relative "../image_store"
require_relative "../delivery"
require_relative "../session_inbox"
require_relative "../log"

module Samagotchi
  class TerminalUI
    # The AttachLink of a session on another machine (chi --remote NAME
    # --attach ID), reached through that machine's chi web: one
    # SessionAccess::WebBridgeClient for the whole attach (a new worker
    # changes its worker_key, never the object), the worker's features from
    # the wake and GET …/worker, and that machine's default model, newest
    # chi and parent strategy. What stays this machine's: the prompt
    # history, the run flags' baselines, the @path files (ingested here,
    # uploaded there).
    class RemoteLink
      include AttachLink

      # The registry ids (SessionCommands' local: true, :attached) the
      # attached loop runs remotely as it does here: its own leaving, the
      # deliveries, the dequeue route, and the exit, archive, stats and
      # recap through chi web's routes.
      HANDLED_COMMANDS = %i[detach cut queue unqueue exit archive stats recap].freeze

      # About a minute of reconnects (P4-D5); a Bridge here keeps
      # EventStream::REDISCOVER_DELAYS.
      RECONNECT_DELAYS = [0.25, 0.5, 1.0, 2.0, 2.0, 3.0, 5.0, 5.0, 5.0, 5.0, 10.0, 10.0, 10.0].freeze
      # How long chi web must answer "no live worker" (not stopped) before
      # the reconnect wakes one (P4-D9): a restart's new worker comes
      # sooner, so it isn't raced.
      WAKE_AFTER = 3.0
      # The wake's wait for a woken worker's Bridge (AttachLauncher's).
      WAKE_WAIT = 10.0

      attr_reader :client

      # @param remote [SessionAccess::Remote]
      # @param session_id [String]
      # @param woke [SessionAccess::WakeReply] the launch's wake
      # @param clock [#call] monotonic seconds
      def initialize(remote:, session_id:, woke:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @remote = remote
        @woke = woke
        @features = Array(woke.worker&.fetch("features", nil))
        @client = remote.attach_client(session_id, worker: woke.worker || {})
        @clock = clock
        @no_worker_since = nil
        @woken_once = false
        @failure = nil
        @default_model = woke.default_model
        @last_records = nil
      end

      # GET …/worker, with the reason when there is none: [client, nil]
      # (its key updated in place: EventStream sees a move when it
      # changed), [nil, reason] to retry, [:gone, reason] to stop. A worker
      # chi web says isn't live and isn't stopped is woken once per
      # outage, after WAKE_AFTER (P4-D9).
      def live_worker
        state = @remote.attach_worker(session_id)
        return [:gone, "stopped"] if state.stopped
        return follow(state.worker) if state.live

        wake_once || [nil, "worker_gone"]
      rescue SessionAccess::AuthRefused, SessionAccess::RemoteTooOld => e
        @failure = e.message
        [:gone, e.is_a?(SessionAccess::AuthRefused) ? "auth_failed" : "too_old"]
      rescue SessionAccess::RemoteFailed => e
        @failure = e.message
        [nil, "unreachable"]
      rescue ArgumentError
        [:gone, "unknown_session"]
      rescue StandardError => e
        Log.debug(:attached, "rediscover_failed", error: e.class.name, message: e.message)
        @failure = e.message
        [nil, "unreachable"]
      end

      # Still the same client (its key moved already: the stream's epoch
      # watch, or #live_worker); the new worker's features read again.
      def switched(event)
        epoch = event[:epoch] || event["epoch"]
        @client.worker_key = epoch if epoch
        refresh_features
        @client
      end

      def queues? = @features.include?(Delivery::QUEUE_FEATURE)

      def unqueues? = @features.include?(SessionInbox::UNQUEUE_FEATURE)

      # Each @path image ingested here (converted and downscaled as chi send
      # does), then uploaded into the session there.
      def ingest_images(paths)
        refs = paths.map { |path| ImageStore.ingest(image_dir, path: path) }
        @remote.upload_images(session_id, refs, from: image_dir)
      rescue SessionAccess::Refused => e
        raise ImageStore::Error, e.message
      rescue SessionAccess::RemoteFailed => e
        raise SessionAccess::WebBridgeClient::Unreachable, e.message
      end

      # A turn's saved records there (GET …/turns/:turn_id/records): [] and
      # nil when they can't be read, as for an older session. A join asks
      # for the tool records, then the turn record, of the same turn: one
      # read gives both, so the second takes what the first read.
      def saved_tool_records(turn_id)
        @last_records = [turn_id, turn_records(turn_id)]
        Array(@last_records[1]&.fetch("tool_records", nil))
      end

      def saved_turn_record(turn_id)
        read = @last_records&.first == turn_id ? @last_records[1] : turn_records(turn_id)
        @last_records = nil
        record = read&.fetch("turn_record", nil)
        record.is_a?(Hash) ? record : nil
      end

      # The delegates' counts there (GET …/children/counts); none when they
      # can't be read (the status row keeps no children segment).
      def children_counts
        json = @client.children_counts
        ChildrenStatus::Counts.new(running: json["running"].to_i, waiting: json["waiting"].to_i,
                                   unreported: json["unreported"].to_i)
      rescue StandardError => e
        Log.debug(:attached, "children_counts_failed", error: e.class.name, message: e.message)
        ChildrenStatus::Counts.none
      end

      # GET …/stats (nil when the worker didn't give them).
      # @raise [SessionAccess::WebBridgeClient::Unreachable] chi web couldn't
      #   be asked, or has no worker for it: the loop says why
      def stats_metrics = @client.stats

      # /exit --delete, once the worker let go: DELETE …?force=true there
      # (SessionManager.delete_session's refusals, raised from chi web's
      # fields).
      def delete_session
        @remote.delete(session_id, force: true)
      rescue SessionAccess::RemoteFailed => e
        raise SessionAccess::WebBridgeClient::Unreachable, e.message
      end

      # /archive: POST …/archive there ({discarded: […]}, as
      # SessionManager.archive_session's).
      def archive_session
        @remote.archive(session_id)
      rescue SessionAccess::RemoteFailed => e
        raise SessionAccess::WebBridgeClient::Unreachable, e.message
      end

      # That machine's newest chi (the wake's).
      def installed_version = @woke.installed

      # That machine's config's default model: the wake's, then the newest
      # worker read's (a restart may come with another config).
      def default_model_name = @default_model

      # Read again now (a parent's report at the end of a run), the wake's
      # when chi web can't be asked.
      def parent_strategy
        @remote.attach_worker(session_id).strategy
      rescue StandardError
        @woke.strategy
      end

      # / commands and this machine's @path files (images are ingested here);
      # no memory names: they would be this machine's (P4-D11).
      def completions = Completions.new(paths: true, memories: false)

      def reconnect_delays = RECONNECT_DELAYS

      def via = @remote.invocation

      # Why chi web couldn't be asked, the last time it couldn't (its
      # message: the remote's label and the cause), for the closing line.
      attr_reader :failure

      # The images' scratch dir goes with the attach.
      def close
        FileUtils.rm_rf(@image_dir) if @image_dir
        @image_dir = nil
      end

      private

      def session_id = @client.session_id

      def image_dir = @image_dir ||= Dir.mktmpdir("chi-attach-images")

      def follow(worker)
        @no_worker_since = nil
        @woken_once = false
        @features = Array(worker&.fetch("features", nil))
        key = worker && (worker["epoch"] || worker["started_at"])
        @client.worker_key = key if key
        [@client, nil]
      end

      # nil while chi web hasn't said "no worker" for WAKE_AFTER yet, or
      # once this outage's wake was made (or failed).
      def wake_once
        now = @clock.call
        @no_worker_since ||= now
        return nil if @woken_once || now - @no_worker_since < WAKE_AFTER

        @woken_once = true
        woke = @remote.attach_wake(session_id, wait: WAKE_WAIT)
        follow(woke.worker)
      rescue SessionAccess::Refused, SessionManager::OwnedByTUI => e
        @failure = e.message
        nil
      end

      # nil without a turn id (an older session's prompt) or when chi web
      # can't give them (a join reads them within JOIN_READ_TIMEOUT).
      def turn_records(turn_id)
        return nil if turn_id.to_s.empty?

        json = @client.turn_records(turn_id)
        json.is_a?(Hash) ? json : nil
      rescue StandardError => e
        Log.debug(:attached, "turn_records_failed", error: e.class.name, message: e.message)
        nil
      end

      def refresh_features
        state = @remote.attach_worker(session_id)
        @features = Array(state.worker&.fetch("features", nil)) if state.live
        @default_model = state.default_model if state.default_model
      rescue StandardError => e
        Log.debug(:attached, "worker_features_failed", error: e.class.name, message: e.message)
      end
    end
  end
end
