# frozen_string_literal: true

require "spec_helper"
require "samagotchi/process_group"

RSpec.describe Samagotchi::ProcessGroup do
  # Every group here is one this spec spawned; each is reaped (or KILLed) after.
  def spawn_group(cmd) = described_class.spawn({}, "sh", "-c", cmd, in: File::NULL, out: File::NULL, err: File::NULL)

  # Signals only a leader not reaped yet: a reaped pid may name another group.
  def reap(pid)
    return if pid.nil? || Process.wait2(pid, Process::WNOHANG)

    described_class.signal(pid, "KILL")
    Process.wait(pid)
  rescue Errno::ECHILD
    nil
  end

  def reaped(pid) = -> { Process.wait2(pid, Process::WNOHANG) }

  describe ".spawn" do
    it "puts the command in a group of its own, led by it" do
      pid = spawn_group("sleep 5")
      expect(Process.getpgid(pid)).to eq(pid)
      expect(Process.getpgid(pid)).not_to eq(Process.getpgrp)
    ensure
      reap(pid)
    end
  end

  describe ".stop" do
    it "TERMs the whole group, a grandchild too, and says it stopped within the grace" do
      pid = spawn_group("sleep 31.91 & wait")
      expect(wait_until { system("pgrep", "-g", pid.to_s, "-f", "sleep 31.91", out: File::NULL) }).to be(true)

      expect(described_class.stop(pid, grace: 2, poll: 0.01, stopped: reaped(pid))).to be(true)
      expect(wait_until { !system("pgrep", "-f", "sleep 31.91", out: File::NULL) }).to be(true)
    ensure
      reap(pid)
    end

    it "KILLs a group that ignores TERM once the grace is over" do
      pid = spawn_group("trap '' TERM; sleep 31.92")
      expect(wait_until { system("pgrep", "-f", "sleep 31.92", out: File::NULL) }).to be(true)
      started = described_class.monotonic

      expect(described_class.stop(pid, grace: 0.2, poll: 0.01, stopped: reaped(pid))).to be(false)
      expect(described_class.monotonic - started).to be >= 0.2
      expect(Process.wait2(pid).last.termsig).to eq(Signal.list["KILL"])
    ensure
      reap(pid)
    end
  end

  describe "a pgid that isn't a group chi may signal" do
    [nil, 0, 1, -5, "123", 12.0].each do |pgid|
      it "is refused for #{pgid.inspect}, nothing signalled" do
        expect(Process).not_to receive(:kill)

        expect { described_class.signal(pgid, "TERM") }.to raise_error(ArgumentError)
        expect { described_class.alive?(pgid) }.to raise_error(ArgumentError)
        expect { described_class.stop(pgid, grace: 0, poll: 0) }.to raise_error(ArgumentError)
        expect(described_class.leader?(pgid)).to be(false)
      end
    end

    it "is no leader when the pid runs in another group" do
      pid = Process.spawn("sleep", "31.93") # this spec's own child, in rspec's group
      expect(described_class.leader?(pid)).to be(false)
      expect(described_class.leader?(Process.pid)).to be(Process.getpgrp == Process.pid)
    ensure
      if pid
        Process.kill("KILL", pid)
        Process.wait(pid)
      end
    end
  end

  describe ".signal" do
    it "says so when there is no such group" do
      pid = spawn_group("exit 0")
      Process.wait(pid)

      expect(described_class.signal(pid, "TERM")).to be(false)
      expect(described_class.alive?(pid)).to be(false)
    end
  end

  describe described_class::PipeReader do
    def read_all(data, **options)
      r, w = IO.pipe
      reader = described_class.new(r, **options)
      w.write(data)
      w.close
      reader.wait(5)
      reader
    ensure
      r.close
    end

    it "reads everything without a cap" do
      expect(read_all("a" * 100_000).text).to eq("a" * 100_000)
    end

    it "stops at the cap with :head, keeping only whole chunks under it" do
      reader = read_all("abcdefgh", cap: 6, chunk: 4)

      expect(reader.over?).to be(true)
      expect(reader.text).to eq("abcd")
    end

    it "keeps the last bytes with :tail" do
      reader = read_all("abcdefgh", cap: 3, keep: :tail, chunk: 2)

      expect(reader.over?).to be(false)
      expect(reader.text).to eq("fgh")
    end

    it "keeps what it read when #finish closes a pipe still held open" do
      r, w = IO.pipe
      reader = described_class.new(r)
      w.write("so far")
      w.flush
      sleep 0.05

      reader.finish(poll: 0.01, grace: 1)

      expect(reader.done?).to be(true)
      expect(reader.text).to eq("so far")
    ensure
      w.close
    end
  end
end
