# frozen_string_literal: true

module Samagotchi
  class TerminalUI
    # What the attached TUI (AttachedLoop) knows about *where* its session
    # is, beside the client it sends requests with: how the worker is found
    # again, what the worker can do, the session's files it reads (images,
    # saved records, children), the session calls it makes (delete,
    # archive), and how the commands it prints are spelled. LocalLink is
    # this machine's (the session's state dir, its worker's Bridge); a
    # remote attach plugs in another.
    #
    # Each method here raises NotImplementedError until a link defines it.
    module AttachLink
      # Which Tab completions the TUI offers beside the / commands.
      # @!attribute paths [Boolean] @path: this machine's files
      # @!attribute memories [Boolean] #name: this machine's memories
      Completions = Data.define(:paths, :memories)

      class Completions
        ALL = new(paths: true, memories: true)
      end

      # The port a worker_changed event names (string or symbol keys; nil
      # for a worker reached another way).
      def self.event_port(event) = event[:port] || event["port"]

      # @return [#session_id, #follow, #post_turn, ...] the session's client
      #   (a BridgeClient on this machine), the newest after #switched
      def client = raise(NotImplementedError)

      # The session's live worker for the stream to follow (EventStream's
      # rediscover).
      # @return [Array(Object, String)] [a client, nil] for a live one,
      #   [nil, nil] while there is none yet, or [:gone, reason] once no
      #   worker is coming
      def live_worker = raise(NotImplementedError)

      # The stream moved to a new worker (its worker_changed event, string
      # or symbol keys): requests go there too.
      # @return [Object] the client from now on (#client)
      def switched(_event) = raise(NotImplementedError)

      # Whether the worker runs delivery: queue (/queue).
      def queues? = raise(NotImplementedError)

      # Whether the worker takes queued messages back (/unqueue).
      def unqueues? = raise(NotImplementedError)

      # The session's metrics for /stats, nil when the worker did not answer.
      # @return [Hash, nil] string keys
      def stats_metrics = raise(NotImplementedError)

      # Store a prompt's @path images where the worker reads them.
      # @param paths [Array<String>] the files as typed
      # @return [Array<Hash>] refs ({file:, name:}) for the turn's images
      # @raise [ImageStore::Error] one can't be used
      def ingest_images(_paths) = raise(NotImplementedError)

      # A turn's saved tool records ([] when none, never raises).
      # @return [Array<Hash>]
      def saved_tool_records(_turn_id) = raise(NotImplementedError)

      # A turn's saved record (nil when none, never raises).
      # @return [Hash, nil]
      def saved_turn_record(_turn_id) = raise(NotImplementedError)

      # The session's delegates' counts, the status row's children segment.
      # @return [ChildrenStatus::Counts]
      def children_counts = raise(NotImplementedError)

      # /exit --delete, once the worker let go.
      def delete_session = raise(NotImplementedError)

      # /archive: SessionManager.archive_session's result ({discarded: […]}).
      # @return [Hash]
      def archive_session = raise(NotImplementedError)

      # The newest chi installed where the worker runs, for the version line.
      # @return [String, nil]
      def installed_version = raise(NotImplementedError)

      # The config's default model where the worker runs, as its /model
      # names it.
      # @return [String, nil]
      def default_model_name = raise(NotImplementedError)

      # What a parent agent may pick on the session's questions, read now
      # (ParentReport.strategy_for).
      def parent_strategy = raise(NotImplementedError)

      # @return [Completions]
      def completions = raise(NotImplementedError)

      # The stream's sleeps between failed reconnects.
      # @return [Array<Float>]
      def reconnect_delays = raise(NotImplementedError)

      # How the commands the TUI prints are spelled.
      # @return [ChiInvocation]
      def via = raise(NotImplementedError)
    end
  end
end
