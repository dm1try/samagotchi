# frozen_string_literal: true

require "tmpdir"
require "socket"
require "spec_helper"
require "samagotchi/worker_link"
require_relative "support/worker_fixtures"

RSpec.describe Samagotchi::WorkerLink do
  include WorkerFixtures

  let(:dir) { Dir.mktmpdir("worker-link") }
  let(:path) { Samagotchi::WorkerSidecar.path(dir) }

  after { FileUtils.rm_rf(dir) }

  # A live worker's: its lock held, its sidecar naming this process.
  def write_sidecar(port, **fields) = live_sidecar_fixture(dir, port: port, **fields)

  def worker(**fields) = Samagotchi::OwnerLock::Owner.new(pid: 4242, kind: "worker", **fields)

  # A port nobody listens on (one just closed).
  def closed_port
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.ip_port.tap { server.close }
  end

  describe ".resolve" do
    it "is None without a sidecar" do
      expect(described_class.resolve(dir, unlink: true)).to eq(described_class::None.new)
      expect(described_class.resolve(dir, unlink: true)).to have_attributes(live?: false, worker_owned?: false, owner: nil)
    end

    it "is Live with the sidecar while a worker holds the lock and the sidecar names its pid" do
      write_sidecar(5001, version: "0.8.1", epoch: "e1", features: ["restart"])

      link = described_class.resolve(dir, unlink: true)
      expect(link).to be_a(described_class::Live)
      expect(link).to have_attributes(live?: true, port: 5001, version: "0.8.1", epoch: "e1", features: ["restart"])
      expect(link.sidecar).to eq(Samagotchi::WorkerSidecar.read(dir))
      expect(File.exist?(path)).to be(true)
    end

    it "is Stale and unlinked when the lock is free, though the sidecar's port still answers (a reused port)" do
      server = TCPServer.new("127.0.0.1", 0)
      Samagotchi::WorkerSidecar.new(port: server.local_address.ip_port, pid: 4242).write(dir)

      expect(described_class.resolve(dir, unlink: false)).to have_attributes(class: described_class::Stale, reason: :lock_free, live?: false)
      expect(File.exist?(path)).to be(true)

      link = described_class.resolve(dir, unlink: true)
      expect(link).to have_attributes(class: described_class::Stale, reason: :lock_free)
      expect(link.sidecar.port).to eq(server.local_address.ip_port)
      expect(File.exist?(path)).to be(false)
    ensure
      server&.close
    end

    it "is Stale under a chi REPL's lock: a TUI writes no sidecar" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242).write(dir)

      hold_worker(dir, kind: "tui") do
        link = described_class.resolve(dir, unlink: true)
        expect(link).to have_attributes(class: described_class::Stale, owner: have_attributes(kind: "tui"))
      end
      expect(File.exist?(path)).to be(false)
    end

    it "is Starting, the file kept, when the lock's holder is not the pid the sidecar names" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: Process.pid + 1).write(dir)

      hold_worker(dir) do
        expect(described_class.resolve(dir, unlink: true)).to have_attributes(class: described_class::Starting, live?: false, worker_owned?: true)
      end
      expect(File.exist?(path)).to be(true)
    end

    it "is Starting, the file kept, for a held lock whose record is still empty" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242).write(dir)

      link = described_class.resolve(dir, unlink: true, owner: Samagotchi::OwnerLock::Owner.new)
      expect(link).to be_a(described_class::Starting)
      expect(File.exist?(path)).to be(true)
    end

    it "is Starting without a port, and stuck once the worker has held the lock past START_LIMIT" do
      File.write(path, JSON.generate(session_id: "s1"))

      fresh = worker(started_at: (Time.now - 5).iso8601(3))
      old = worker(started_at: (Time.now - 31).iso8601(3))
      expect(described_class.resolve(dir, unlink: true, owner: fresh)).to have_attributes(class: described_class::Starting, stuck: false)
      expect(described_class.resolve(dir, unlink: true, owner: old)).to have_attributes(class: described_class::Starting, stuck: true)
      expect(File.exist?(path)).to be(true)
    end

    it "is Live for an older worker's sidecar with no pid, on the lock alone" do
      File.write(path, JSON.generate(port: 5001, session_id: "s1"))

      expect(described_class.resolve(dir, unlink: true, owner: worker)).to be_a(described_class::Live)
    end

    it "reads a port written as a string" do
      File.write(path, JSON.generate(port: "5001"))

      expect(described_class.resolve(dir, unlink: true, owner: worker).port).to eq(5001)
    end

    it "is Leaving for a leaving worker, even with a sidecar" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242).write(dir)
      leaving = worker(leaving_at: Time.now.iso8601(3), leave_wait: 20.0)

      expect(described_class.resolve(dir, unlink: true, owner: leaving)).to have_attributes(class: described_class::Leaving, live?: false, worker_owned?: true)
      expect(File.exist?(path)).to be(true)
    end

    it "is Skew, not live, for a sidecar of a newer protocol" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242, protocol: described_class::PROTOCOL + 1, version: "9.0.0").write(dir)

      link = described_class.resolve(dir, unlink: true, owner: worker)
      expect(link).to have_attributes(class: described_class::Skew, live?: false, worker_owned?: true)
      expect(link.message("s1")).to include("s1", "9.0.0", "protocol #{described_class::PROTOCOL + 1}")
    end

    it "takes the owner it is given without reading the lock" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242).write(dir)
      expect(Samagotchi::OwnerLock).not_to receive(:owner)

      expect(described_class.resolve(dir, unlink: true, owner: worker)).to be_a(described_class::Live)
      expect(described_class.resolve(dir, unlink: false, owner: nil)).to be_a(described_class::Stale)
    end

    it "keeps a sidecar a new worker wrote between the read and the unlink" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242, epoch: "old").write(dir)
      allow(Samagotchi::WorkerSidecar).to receive(:read).and_wrap_original do |original, *args|
        original.call(*args).tap { Samagotchi::WorkerSidecar.new(port: 5002, pid: 4343, epoch: "new").write(dir) }
      end

      expect(described_class.resolve(dir, unlink: true, owner: nil)).to have_attributes(class: described_class::Stale)
      expect(Samagotchi::WorkerSidecar.read(dir)).to have_attributes(epoch: "new")
    end

    it "is None for a broken sidecar" do
      ["{", "[1]"].each do |body|
        File.write(path, body)
        expect(described_class.resolve(dir, unlink: true, owner: nil)).to eq(described_class::None.new), body
      end
    end
  end

  describe ".not_live" do
    it "owns the one no-live-worker message with the session id" do
      expect(described_class.not_live("s-1234")).to eq("no live worker for session s-1234")
    end
  end

  describe "Skew#message" do
    it "names the newer worker and commands through the supplied invocation" do
      link = described_class::Skew.new(
        sidecar: Samagotchi::WorkerSidecar.new(port: 5001, version: "9.0.0", protocol: 2),
        owner: worker, reason: :protocol
      )
      via = Samagotchi::ChiInvocation.new(remote: "studio")

      message = link.message("s-1234", via: via)

      expect(message).to include("session s-1234's worker runs chi 9.0.0 (protocol 2)")
      expect(message).to include(via.web, "update this chi")
    end
  end

  describe ".client" do
    it "is a client for the Live worker (its port and secret), else nil" do
      write_sidecar(5001, secret: "5e" * 32)

      client = described_class.client("s1", session_dir: dir, read_timeout: 3)
      expect(client).to have_attributes(session_id: "s1", port: 5001)
      expect(client.instance_variable_get(:@secret)).to eq("5e" * 32)

      release_worker_locks
      expect(described_class.client("s1", session_dir: dir)).to be_nil
      expect(File.exist?(path)).to be(false)
    end
  end

  describe ".await" do
    it "stops at the first outcome give_up holds for, before its timeout" do
      started = Time.now
      link = described_class.await("s1", session_dir: dir, timeout: 5, interval: 0.001, unlink: false,
                                         give_up: ->(outcome) { !outcome.worker_owned? })
      expect(link).to have_attributes(live?: false, worker_owned?: false)
      expect(Time.now - started).to be < 4
    end

    it "returns the first Live for which until holds" do
      write_sidecar(5001, started_at: "old")
      looks = 0
      allow(described_class).to receive(:resolve).and_wrap_original do |original, *args, **kw|
        looks += 1
        write_sidecar(5002, started_at: "fresh") if looks == 3
        original.call(*args, **kw)
      end

      link = described_class.await("s1", session_dir: dir, timeout: 5, interval: 0.001, unlink: false,
                                   until: ->(live) { live.started_at != "old" })
      expect(link).to have_attributes(live?: true, started_at: "fresh", port: 5002)
    end

    it "with only the old worker's sidecar, times out with that Live as the last outcome" do
      write_sidecar(5001, started_at: "old")

      link = described_class.await("s1", session_dir: dir, timeout: 0.05, interval: 0.01, unlink: false,
                                   until: ->(live) { live.started_at != "old" })
      expect(link).to have_attributes(live?: true, started_at: "old")
    end

    it "is the Live once the worker publishes its sidecar late; its client is the worker's" do
      hold_worker(dir)
      writer = Thread.new do
        sleep 0.25 # sleep-ok: the worker publishing its sidecar late is the behaviour
        Samagotchi::WorkerSidecar.new(port: 5001, pid: Process.pid).write(dir)
      end

      link = described_class.await("s1", session_dir: dir, timeout: 3)
      expect(link).to be_a(described_class::Live)
      expect(link.client("s1")).to have_attributes(port: 5001, session_id: "s1")
    ensure
      writer&.join
    end

    it "gives up at the deadline, not much past it" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(described_class.await("s1", session_dir: dir, timeout: 0.3).live?).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.3, 2.0)
    end

    it "takes any Live without until, and is the last outcome (None) when none came" do
      expect(described_class.await("s1", session_dir: dir, timeout: 0.03, interval: 0.01)).to eq(described_class::None.new)

      write_sidecar(5001)
      expect(described_class.await("s1", session_dir: dir, timeout: 1)).to have_attributes(live?: true)
    end
  end

  describe ".each_dir" do
    it "lists the session folders holding a sidecar, in order" do
      %w[b a].each { |id| Samagotchi::WorkerSidecar.new(port: 1).write(File.join(dir, id)) }
      FileUtils.mkdir_p(File.join(dir, "c"))

      expect(described_class.each_dir(dir)).to eq([File.join(dir, "a"), File.join(dir, "b")])
    end
  end
end
