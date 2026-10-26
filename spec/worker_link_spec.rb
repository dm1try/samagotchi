# frozen_string_literal: true

require "tmpdir"
require "socket"
require "spec_helper"
require "samagotchi/worker_link"

RSpec.describe Samagotchi::WorkerLink do
  let(:dir) { Dir.mktmpdir("worker-link") }
  let(:path) { Samagotchi::WorkerSidecar.path(dir) }

  after { FileUtils.rm_rf(dir) }

  def write_sidecar(port, **fields) = Samagotchi::WorkerSidecar.new(port: port, **fields).write(dir)

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

    it "is Live with the sidecar while its port takes a connect" do
      server = TCPServer.new("127.0.0.1", 0)
      write_sidecar(server.local_address.ip_port, version: "0.8.1", epoch: "e1", features: ["restart"])

      link = described_class.resolve(dir, unlink: true)
      expect(link).to be_a(described_class::Live)
      expect(link).to have_attributes(live?: true, port: server.local_address.ip_port, version: "0.8.1", epoch: "e1",
                                      features: ["restart"])
      expect(link.sidecar).to eq(Samagotchi::WorkerSidecar.read(dir))
      expect(File.exist?(path)).to be(true)
    ensure
      server&.close
    end

    # The macOS 26 regression: Socket.tcp with connect_timeout handed back a
    # refused connect's socket, so a dead worker's port read as live (Ruby
    # bug #22223); the TCPSocket probe raises ECONNREFUSED.
    it "is Stale(:port_closed) on a closed port, and removes the sidecar only with unlink: true" do
      write_sidecar(closed_port)

      expect(described_class.resolve(dir, unlink: false))
        .to have_attributes(class: described_class::Stale, reason: :port_closed, live?: false)
      expect(File.exist?(path)).to be(true)

      link = described_class.resolve(dir, unlink: true)
      expect(link).to have_attributes(class: described_class::Stale, reason: :port_closed)
      expect(link.sidecar.port).to be_positive
      expect(File.exist?(path)).to be(false)
    end

    it "reads a port written as a string; a sidecar naming no port is Stale(:no_port) and kept, a broken one None" do
      server = TCPServer.new("127.0.0.1", 0)
      File.write(path, JSON.generate(port: server.local_address.ip_port.to_s))
      expect(described_class.resolve(dir, unlink: true).port).to eq(server.local_address.ip_port)

      [JSON.generate(port: 0), JSON.generate(session_id: "s1")].each do |body|
        File.write(path, body)
        expect(described_class.resolve(dir, unlink: true)).to have_attributes(class: described_class::Stale, reason: :no_port), body
        expect(File.exist?(path)).to be(true)
      end
      ["{", "[1]"].each do |body|
        File.write(path, body)
        expect(described_class.resolve(dir, unlink: true)).to eq(described_class::None.new), body
      end
    ensure
      server&.close
    end
  end

  describe ".client" do
    it "is a client for the Live worker (its port and secret), else nil" do
      server = TCPServer.new("127.0.0.1", 0)
      write_sidecar(server.local_address.ip_port, secret: "5e" * 32)

      client = described_class.client("s1", session_dir: dir, read_timeout: 3)
      expect(client).to have_attributes(session_id: "s1", port: server.local_address.ip_port)
      expect(client.instance_variable_get(:@secret)).to eq("5e" * 32)

      server.close
      expect(described_class.client("s1", session_dir: dir)).to be_nil
      expect(File.exist?(path)).to be(false)
    ensure
      server&.close unless server&.closed?
    end
  end

  describe ".await" do
    it "returns the first Live for which until holds" do
      old = TCPServer.new("127.0.0.1", 0)
      fresh = TCPServer.new("127.0.0.1", 0)
      write_sidecar(old.local_address.ip_port, started_at: "old")
      looks = 0
      allow(described_class).to receive(:resolve).and_wrap_original do |original, *args, **kw|
        looks += 1
        write_sidecar(fresh.local_address.ip_port, started_at: "fresh") if looks == 3
        original.call(*args, **kw)
      end

      link = described_class.await("s1", session_dir: dir, timeout: 5, interval: 0.001, unlink: false,
                                   until: ->(live) { live.started_at != "old" })
      expect(link).to have_attributes(live?: true, started_at: "fresh", port: fresh.local_address.ip_port)
    ensure
      old&.close
      fresh&.close
    end

    it "with only the old worker's sidecar, times out with that Live as the last outcome" do
      server = TCPServer.new("127.0.0.1", 0)
      write_sidecar(server.local_address.ip_port, started_at: "old")

      link = described_class.await("s1", session_dir: dir, timeout: 0.05, interval: 0.01, unlink: false,
                                   until: ->(live) { live.started_at != "old" })
      expect(link).to have_attributes(live?: true, started_at: "old")
    ensure
      server&.close
    end

    it "is the Live once the worker publishes its sidecar late; its client is the worker's" do
      server = TCPServer.new("127.0.0.1", 0)
      writer = Thread.new do
        sleep 0.25 # sleep-ok: the worker publishing its sidecar late is the behaviour
        File.write(path, JSON.generate(port: server.local_address.ip_port))
      end

      client = described_class.await("s1", session_dir: dir, timeout: 3).client("s1")

      expect(client.port).to eq(server.local_address.ip_port)
      expect(client.session_id).to eq("s1")
    ensure
      writer&.join
      server&.close
    end

    it "gives up at the deadline, not much past it" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(described_class.await("s1", session_dir: dir, timeout: 0.3).live?).to be(false)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(0.3, 2.0)
    end

    it "takes any Live without until, and is the last outcome (None) when none came" do
      expect(described_class.await("s1", session_dir: dir, timeout: 0.03, interval: 0.01)).to eq(described_class::None.new)

      server = TCPServer.new("127.0.0.1", 0)
      write_sidecar(server.local_address.ip_port)
      expect(described_class.await("s1", session_dir: dir, timeout: 1)).to have_attributes(live?: true)
    ensure
      server&.close
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
