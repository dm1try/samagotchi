# frozen_string_literal: true

require "fileutils"
require "time"
require_relative "owner_lock"
require_relative "version"
require_relative "worker_sidecar"
require_relative "bridge_client"
require_relative "chi_invocation"

module Samagotchi
  # Whether a session's worker can be reached, and how: the one question
  # every client asks before it talks to a worker's Bridge (a TUI attaching,
  # chi web's relays and stream, `chi send`, a restart, `chi update`). It
  # answers a typed outcome instead of a sidecar or nil, so nobody reads
  # bridge.json by hand. The rule is the owner lock plus the sidecar's pid,
  # never a port probe:
  # - Live: a worker holds the lock and its sidecar names its pid (a sidecar
  #   with no pid: an older worker's, the lock alone) (#client makes the one
  #   client for it);
  # - Starting: a worker holds the lock but has no sidecar of its own yet (or
  #   the lock's record is still being written); stuck when it has held it
  #   past START_LIMIT without one;
  # - Leaving: the worker closed its Bridge and holds the lock for its last work;
  # - Skew: a worker whose sidecar speaks a newer PROTOCOL than this chi;
  # - Stale: a sidecar, but the lock is free (or a chi REPL holds it, which
  #   writes none): its worker died;
  # - None: no worker and no sidecar, or a chi REPL.
  # A kernel releases a dead worker's lock, so a free lock is the proof of
  # death a TCP probe never gave (a port can be reused by another session's
  # Bridge).
  module WorkerLink
    # The sidecar protocol this chi speaks; a sidecar with a bigger one is a
    # newer worker's (Skew).
    PROTOCOL = 1

    # Seconds a worker may hold the lock without publishing its Bridge before
    # Starting is stuck (SessionManager::WORKER_START_GRACE).
    START_LIMIT = 30.0

    # The sidecar's file name in a session folder.
    FILE = WorkerSidecar::FILE

    # A worker whose Bridge answers: its sidecar says how to reach it.
    Live = Data.define(:sidecar, :owner) do
      def initialize(sidecar:, owner: nil) = super

      def live? = true
      def worker_owned? = true

      # The client for this worker (BridgeClient.for_sidecar: its port and its
      # secret from this one read).
      # @return [BridgeClient]
      def client(session_id, host: BridgeClient::HOST, read_timeout: BridgeClient::READ_TIMEOUT)
        BridgeClient.for_sidecar(session_id, sidecar, host: host, read_timeout: read_timeout)
      end

      def port = sidecar.port
      def epoch = sidecar.epoch
      def version = sidecar.version
      def features = sidecar.features
      def started_at = sidecar.started_at
    end

    # A worker holds the lock and has not published its Bridge (yet).
    Starting = Data.define(:owner, :stuck) do
      def initialize(owner:, stuck: false) = super

      def live? = false
      def worker_owned? = true
    end

    # A worker holds the lock with its Bridge closed (OwnerLock::Owner#leaving?).
    Leaving = Data.define(:owner) do
      def live? = false
      def worker_owned? = true

      # Seconds of its leave still to run.
      def left = owner.leave_left
    end

    # No worker: no sidecar in the session folder, and no worker's lock (a
    # chi REPL's, +owner+, is no worker's).
    None = Data.define(:owner) do
      def initialize(owner: nil) = super

      def live? = false
      def worker_owned? = false
    end

    # A sidecar no worker stands behind: the lock is free (reason :lock_free).
    Stale = Data.define(:sidecar, :reason, :owner) do
      def initialize(sidecar:, reason:, owner: nil) = super

      def live? = false
      def worker_owned? = false
    end

    # A worker whose sidecar's protocol is newer than this chi's (reason
    # :protocol): it must not be driven by this chi.
    Skew = Data.define(:sidecar, :owner, :reason) do
      def live? = false
      def worker_owned? = true

      def message(session_id, via: ChiInvocation::HERE)
        "session #{session_id}'s worker runs chi #{sidecar.version || "?"} (protocol #{sidecar.protocol}), " \
          "newer than this chi #{Samagotchi::VERSION} (protocol #{PROTOCOL}): restart " \
          "#{via.remote? ? via.web : "chi web"} or update this chi"
      end
    end

    module_function

    def not_live(session_id) = "no live worker for session #{session_id}"
    def unanswered(session_id) = "the worker for session #{session_id} didn't answer"

    # @param session_dir [String]
    # @param unlink [Boolean] remove a Stale sidecar (the clients that would
    #   talk to it; never one a worker may be writing); false is a read-only
    #   look (`chi update`, a restart's poll)
    # @param owner [OwnerLock::Owner, nil, :read] the lock's holder as the
    #   caller already read it (nil: free); :read reads it here
    # @return [Live, Starting, Leaving, None, Stale, Skew]
    def resolve(session_dir, unlink:, owner: :read)
      owner = OwnerLock.owner(session_dir) if owner == :read
      stamp = file_stamp(session_dir)
      sidecar = WorkerSidecar.read(session_dir)
      return unowned(session_dir, sidecar, owner, stamp, unlink) if owner.nil? || owner.tui?
      return Starting.new(owner: owner, stuck: false) unless owner.worker?
      return Leaving.new(owner: owner) if owner.leaving?
      return Starting.new(owner: owner, stuck: stuck?(owner)) unless ours?(sidecar, owner)
      return Skew.new(sidecar: sidecar, owner: owner, reason: :protocol) if sidecar.protocol.to_i > PROTOCOL

      Live.new(sidecar: sidecar, owner: owner)
    end

    # @return [BridgeClient, nil] a client for the session's Live worker
    def client(session_id, session_dir:, unlink: true, host: BridgeClient::HOST, read_timeout: BridgeClient::READ_TIMEOUT)
      link = resolve(session_dir, unlink: unlink)
      link.live? ? link.client(session_id, host: host, read_timeout: read_timeout) : nil
    end

    # Wait for a worker (a freshly spawned one) to publish its Bridge: the
    # first Live for which +until+ holds within +timeout+ seconds (polled
    # every +interval+), else the last outcome seen. +until+ tells a new
    # worker from the one a restart asked to leave (its sidecar is Live too).
    # @param _session_id [String] the session waited for (as .client's; the
    #   outcome's #client takes it again)
    # @param until [#call, nil] ->(live) { … }; nil takes any Live
    # @param give_up [#call, nil] ->(outcome) { … }: stop at the first
    #   outcome it holds for (a waker's "no worker owns it any more")
    # @return [Live, Starting, Leaving, None, Stale, Skew] the outcome it
    #   stopped at, else the last one seen
    def await(_session_id, session_dir:, timeout:, unlink: true, interval: BridgeClient::SPAWN_POLL_INTERVAL,
              until: nil, give_up: nil)
      wanted = binding.local_variable_get(:until) # a keyword: no plain read
      last = nil
      found = BridgeClient.poll(timeout, interval: interval) do
        last = resolve(session_dir, unlink: unlink)
        last if (last.live? && (wanted.nil? || wanted.call(last))) || give_up&.call(last)
      end
      found || last
    end

    # The session folders under +state_dir+ that hold a sidecar (live or not),
    # in order.
    # @return [Array<String>]
    def each_dir(state_dir)
      Dir[File.join(state_dir, "*", WorkerSidecar::FILE)].sort.map { |path| File.dirname(path) }
    end

    # A sidecar is the lock holder's own when it names its pid (or none: an
    # older worker's) and a port.
    def ours?(sidecar, owner)
      return false unless sidecar&.port&.positive?

      sidecar.pid.nil? || sidecar.pid == owner.pid
    end
    private_class_method :ours?

    def stuck?(owner)
      started = Time.iso8601(owner.started_at.to_s)
      Time.now - started > START_LIMIT
    rescue ArgumentError
      false
    end
    private_class_method :stuck?

    def unowned(session_dir, sidecar, owner, stamp, unlink)
      return None.new(owner: owner) unless sidecar

      if unlink
        # A worker that took the lock and wrote its sidecar since the lock
        # was read (before the stamp): its fresh file is the one stamped, so
        # read the lock again just before the unlink, and take that worker.
        fresh = OwnerLock.owner(session_dir)
        return resolve(session_dir, unlink: false, owner: fresh) if fresh&.worker?

        unlink_unchanged(session_dir, stamp)
      end
      Stale.new(sidecar: sidecar, reason: :lock_free, owner: owner)
    end
    private_class_method :unowned

    def file_stamp(session_dir)
      stat = File.stat(WorkerSidecar.path(session_dir))
      [stat.ino, stat.mtime]
    rescue SystemCallError
      nil
    end
    private_class_method :file_stamp

    # Remove the sidecar only if it is the file that was read: a new worker's
    # write is a new inode (AtomicFile renames).
    def unlink_unchanged(session_dir, stamp)
      return if stamp.nil? || file_stamp(session_dir) != stamp

      FileUtils.rm_f(WorkerSidecar.path(session_dir))
    end
    private_class_method :unlink_unchanged
  end
end
