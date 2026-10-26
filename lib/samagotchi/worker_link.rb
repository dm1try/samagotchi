# frozen_string_literal: true

require "fileutils"
require "socket"
require_relative "worker_sidecar"
require_relative "bridge_client"

module Samagotchi
  # Whether a session's worker can be reached, and how: the one question
  # every client asks before it talks to a worker's Bridge (a TUI attaching,
  # chi web's relays and stream, `chi send`, a restart, `chi update`). It
  # answers a typed outcome instead of a sidecar or nil, so nobody reads
  # bridge.json or probes a port by hand:
  # - Live: the worker's Bridge takes a connect on the port its sidecar names
  #   (#client makes the one client for it);
  # - Stale: a sidecar is there but its port refuses a connect (its worker
  #   died; reason :port_closed), or it names no port (:no_port);
  # - None: no sidecar.
  # The rule is the sidecar plus a TCP probe (today's); its owner is not
  # read yet (nil).
  module WorkerLink
    # Seconds the liveness probe waits for the port to take a connect.
    PROBE_TIMEOUT = 0.2

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

    # No sidecar in the session folder: no worker publishes a Bridge there.
    None = Data.define(:owner) do
      def initialize(owner: nil) = super

      def live? = false
      def worker_owned? = false
    end

    # A sidecar no live Bridge stands behind (see the module comment).
    Stale = Data.define(:sidecar, :reason) do
      def live? = false
      def worker_owned? = false
      def owner = nil
    end

    module_function

    # @param session_dir [String]
    # @param unlink [Boolean] remove a Stale sidecar whose port refused (the
    #   clients that would talk to it); false is a read-only look (`chi
    #   update`, a restart's poll)
    # @return [Live, None, Stale]
    def resolve(session_dir, unlink:, host: BridgeClient::HOST)
      sidecar = WorkerSidecar.read(session_dir)
      return None.new unless sidecar
      return Stale.new(sidecar: sidecar, reason: :no_port) unless sidecar.port&.positive?
      return Live.new(sidecar: sidecar) if probe(host, sidecar.port)

      FileUtils.rm_f(WorkerSidecar.path(session_dir)) if unlink
      Stale.new(sidecar: sidecar, reason: :port_closed)
    end

    # @return [BridgeClient, nil] a client for the session's Live worker
    def client(session_id, session_dir:, unlink: true, host: BridgeClient::HOST, read_timeout: BridgeClient::READ_TIMEOUT)
      link = resolve(session_dir, unlink: unlink, host: host)
      link.live? ? link.client(session_id, host: host, read_timeout: read_timeout) : nil
    end

    # Wait for a worker (a freshly spawned one) to publish its Bridge: the
    # first Live for which +until+ holds within +timeout+ seconds (polled
    # every +interval+), else the last outcome seen. +until+ tells a new
    # worker from the one a restart asked to leave (its sidecar is Live too).
    # @param _session_id [String] the session waited for (as .client's; the
    #   outcome's #client takes it again)
    # @param until [#call, nil] ->(live) { … }; nil takes any Live
    # @return [Live, None, Stale]
    def await(_session_id, session_dir:, timeout:, unlink: true, interval: BridgeClient::SPAWN_POLL_INTERVAL,
              until: nil, host: BridgeClient::HOST)
      wanted = binding.local_variable_get(:until) # a keyword: no plain read
      last = nil
      found = BridgeClient.poll(timeout, interval: interval) do
        last = resolve(session_dir, unlink: unlink, host: host)
        last if last.live? && (wanted.nil? || wanted.call(last))
      end
      found || last
    end

    # The session folders under +state_dir+ that hold a sidecar (live or not),
    # in order.
    # @return [Array<String>]
    def each_dir(state_dir)
      Dir[File.join(state_dir, "*", WorkerSidecar::FILE)].sort.map { |path| File.dirname(path) }
    end

    # Whether +port+ takes a connect.
    def probe(host, port, timeout: PROBE_TIMEOUT)
      # Not Socket.tcp: with connect_timeout on macOS 26 it hands back the
      # socket of a refused connect (the kernel's second connect() says
      # EISCONN, SO_ERROR is unchecked), so a dead worker's port read as
      # live. Ruby bug #22223, fixed in 3.4.11 / 4.0.7, not in 3.3.
      # TCPSocket checks SO_ERROR and raises ECONNREFUSED on every Ruby,
      # so this stays even once 3.3 is dropped.
      TCPSocket.new(host, port, connect_timeout: timeout).close
      true
    rescue StandardError
      false
    end
    private_class_method :probe
  end
end
