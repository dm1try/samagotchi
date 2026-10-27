# frozen_string_literal: true

require "samagotchi/owner_lock"
require "samagotchi/worker_sidecar"
require "samagotchi/worker_link"

# A session folder that WorkerLink reads as Live: a worker holds the owner
# lock (WorkerLink's rule is the lock plus the sidecar's pid, no port probe)
# and its sidecar names this process. flock conflicts across descriptors in
# one process, as OwnerLock's comment says, so the lock held here is a
# worker's to any OwnerLock.owner call. Include it in the example group;
# every lock taken is released after the example.
module WorkerFixtures
  def self.included(base)
    base.after { release_worker_locks }
  end

  # Hold the session's owner lock as a worker for the block (without a block:
  # until the example ends).
  # @return [OwnerLock] the lock
  def hold_worker(session_dir, kind: "worker")
    lock = Samagotchi::OwnerLock.acquire(session_dir, kind: kind, wait: 0)
    raise "owner lock of #{session_dir} is already held" unless lock

    worker_locks << lock
    return lock unless block_given?

    begin
      yield lock
    ensure
      lock.release
      worker_locks.delete(lock)
    end
  end

  # A worker's lock (taken once per folder: call again to rewrite the
  # sidecar) and its sidecar for a Bridge on +port+.
  # @param fields [Hash] more WorkerSidecar fields (version:, features:, epoch: …)
  # @return [Samagotchi::WorkerSidecar]
  def live_sidecar_fixture(session_dir, port:, secret: nil, **fields)
    hold_worker(session_dir) unless worker_dirs.include?(session_dir)
    worker_dirs << session_dir
    sidecar = Samagotchi::WorkerSidecar.new(port: port, secret: secret, pid: Process.pid,
                                            protocol: Samagotchi::WorkerLink::PROTOCOL, **fields)
    sidecar.write(session_dir)
    sidecar
  end

  def release_worker_locks
    worker_locks.each(&:release)
    worker_locks.clear
    worker_dirs.clear
  end

  def worker_dirs = (@worker_dirs ||= [])

  def worker_locks = (@worker_locks ||= [])
end
