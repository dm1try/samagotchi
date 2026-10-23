# frozen_string_literal: true

require_relative "attach_link"
require_relative "../session"
require_relative "../bridge_client"
require_relative "../worker_sidecar"
require_relative "../delivery"
require_relative "../session_inbox"
require_relative "../image_store"
require_relative "../session_metrics"
require_relative "../children_status"
require_relative "../session_manager"
require_relative "../installed_versions"
require_relative "../model_profile"
require_relative "../parent_report"
require_relative "../chi_invocation"

module Samagotchi
  class TerminalUI
    # The AttachLink of a session on this machine: its worker's Bridge
    # (found through the sidecar in the session folder) and the session's
    # files under +state_dir+.
    class LocalLink
      include AttachLink

      # How long /exit --delete and /archive wait for the worker to let go
      # (AttachedLoop's defaults too).
      DELETE_WAIT = 10

      attr_reader :client

      # @param client [BridgeClient] the live worker's
      # @param state_dir [String] the state dir the worker was found in
      # @param delete_session [#call] session id -> deletes it
      # @param archive_session [#call] session id -> archives it
      #   (SessionManager.archive_session's result)
      # @param installed_version [#call] -> the newest chi installed
      # @param children_counts [#call] session id -> ChildrenStatus::Counts
      def initialize(client:, state_dir: Session.default_state_dir,
                     delete_session: ->(id) { SessionManager.delete_session(id, stop: true, wait: DELETE_WAIT) },
                     archive_session: ->(id) { SessionManager.archive_session(id, wait: DELETE_WAIT) },
                     installed_version: -> { InstalledVersions.new.newest },
                     children_counts: ->(id) { ChildrenStatus.counts(id, state_dir: state_dir) })
        @client = client
        @state_dir = state_dir
        @delete_session = delete_session
        @archive_session = archive_session
        @installed_version = installed_version
        @children_counts = children_counts
      end

      # The sidecar's worker, nil while none runs; gone once the session was
      # stopped (no worker is coming): its stop marker in +state_dir+.
      def live_worker
        id = @client.session_id
        return [:gone, "stopped"] if Session.stopped_marker?(id, state_dir: @state_dir)

        [BridgeClient.discover(id, session_dir: session_dir, host: @client.host), nil]
      end

      # A new worker's Bridge, on the port its event names.
      def switched(event)
        @client = BridgeClient.new(session_id: @client.session_id, port: AttachLink.event_port(event), host: @client.host)
      end

      # No sidecar to read: true, its Bridge answers (a P0-P2 worker refuses
      # a queue).
      def queues? = feature?(Delivery::QUEUE_FEATURE)

      # No sidecar to read: true, its Bridge answers (an older one's 404
      # not_found says so).
      def unqueues? = feature?(SessionInbox::UNQUEUE_FEATURE)

      # The worker's stats; a worker from before the stats route answers
      # only /state.
      def stats_metrics
        @client.get_json("stats")&.dig("metrics") || @client.get_json("state")&.dig("session_state_snapshot", "metrics")
      end

      # Stored in the session's images/ here (the worker's state dir).
      def ingest_images(paths)
        paths.map do |path|
          ref = ImageStore.ingest(session_dir, path: path)
          { file: ref[:file], name: ref[:name] }
        end
      end

      # SessionMetrics, in this machine's state dir: none for a prompt with
      # no turn id (an older session) or a session with no analytics.
      def saved_tool_records(turn_id)
        SessionMetrics.saved_tool_records(session_dir, turn_id)
      rescue Session::InvalidId
        []
      end

      def saved_turn_record(turn_id)
        SessionMetrics.saved_turn_record(session_dir, turn_id)
      rescue Session::InvalidId
        nil
      end

      def children_counts = @children_counts.call(@client.session_id)

      def delete_session = @delete_session.call(@client.session_id)

      def archive_session = @archive_session.call(@client.session_id)

      def installed_version = @installed_version.call

      def default_model_name = ModelProfile.default_model_name

      def parent_strategy = ParentReport.strategy_for(@client.session_id, state_dir: @state_dir)

      def completions = Completions::ALL

      def reconnect_delays = BridgeClient::EventStream::REDISCOVER_DELAYS

      def via = ChiInvocation::HERE

      # The closing line says it all (unreachable, unknown_session).
      def failure = nil

      def close = nil

      private

      def session_dir = Session.session_dir(@client.session_id, state_dir: @state_dir)

      def feature?(name)
        sidecar = WorkerSidecar.read(session_dir)
        sidecar.nil? || sidecar.features.include?(name)
      end
    end
  end
end
