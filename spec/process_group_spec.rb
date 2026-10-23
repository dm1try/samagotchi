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

  # True once the pid is reaped, here or already (ECHILD).
  def reaped(pid)
    lambda do
      !Process.wait2(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end
  end

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
      wait_for("the grandchild sleep") { system("pgrep", "-g", pid.to_s, "-f", "sleep 31.91", out: File::NULL) }

      expect(described_class.stop(pid, grace: 2, poll: 0.01, stopped: reaped(pid))).to be(true)
      wait_for("the grandchild to be stopped") { !system("pgrep", "-f", "sleep 31.91", out: File::NULL) }
    ensure
      reap(pid)
    end

    it "KILLs a group that ignores TERM once the grace is over, and waits until it has stopped" do
      pid = spawn_group("trap '' TERM; sleep 31.92")
      wait_for("the TERM-ignoring sleep") { system("pgrep", "-f", "sleep 31.92", out: File::NULL) }
      started = described_class.monotonic
      status = nil
      gone = -> { status ||= Process.wait2(pid, Process::WNOHANG)&.last }

      expect(described_class.stop(pid, grace: 0.2, poll: 0.01, stopped: gone)).to be(false)
      expect(described_class.monotonic - started).to be >= 0.2
      expect(status&.termsig).to eq(Signal.list["KILL"])
    ensure
      reap(pid) unless status
    end

    # A `timeout N cmd` (GNU, no --foreground) moves itself to a group of
    # its own: ruby's setpgid stands in for it, no coreutils needed.
    describe "a descendant that left the group" do
      def spawn_leaver(marker)
        spawn_group("ruby -e 'Process.setpgid(0, 0); sleep #{marker}'; echo after")
      end

      # The ruby that left (its own group's leader), not the shell +shell+
      # whose command line names it too.
      def leaver_pids(marker, shell)
        `pgrep -f "sleep #{marker}"`.split.map(&:to_i).select do |p|
          p != shell && Process.getpgid(p) == p
        rescue Errno::ESRCH
          false
        end
      end

      it "is stopped with the group (its group found while the shell runs)" do
        pid = spawn_leaver(31.93)
        wait_for("the leaver") { leaver_pids(31.93, pid).any? }

        expect(described_class.stop(pid, grace: 2, poll: 0.01, stopped: reaped(pid))).to be(true)
        wait_for("the leaver to be stopped") { leaver_pids(31.93, pid).empty? }
      ensure
        reap(pid)
      end

      it "survives a stop without the walk" do
        pid = spawn_leaver(31.94)
        wait_for("the leaver") { leaver_pids(31.94, pid).any? }
        leavers = leaver_pids(31.94, pid)

        described_class.stop(pid, grace: 2, poll: 0.01, stopped: reaped(pid), walk: false)
        expect(leavers.all? { |p| described_class.alive?(p) }).to be(true)
      ensure
        reap(pid)
        # Its own group, which this example started: never the walk's.
        Array(leavers).each { |p| described_class.signal(p, "KILL") }
      end
    end

    it "walks from the group's members only, from the bare pid with leader:, never into chi's own group" do
      table = [[100, 1, 100], [200, 100, 200], [201, 200, 200], [300, 50, 300], [400, 300, 400],
               [500, 100, Process.getpgrp], [600, 100, 1]]
      allow(described_class).to receive(:process_table).and_return(table)

      expect(described_class.descendant_groups(100)).to eq([200])
      expect(described_class.descendant_groups(50)).to eq([])
      expect(described_class.descendant_groups(50, leader: true)).to eq([300, 400])
    end

    it "asks +stopped+ no more once it said true, while it waits for the descendants' groups" do
      calls = 0
      allow(described_class).to receive(:descendant_groups).and_return([4242])
      allow(described_class).to receive(:signal)
      allow(described_class).to receive(:group_alive?).with(4242).and_return(true, true, false)

      expect(described_class.stop(4241, grace: 1, poll: 0.01, stopped: -> { (calls += 1) == 1 })).to be(true)
      expect(calls).to eq(1)
    end

    it "waits at most kill_wait after the KILL for a group that never says it stopped" do
      pid = spawn_group("trap '' TERM; sleep 31.99")
      started = described_class.monotonic

      expect(described_class.stop(pid, grace: 0.05, poll: 0.01, stopped: -> { false }, kill_wait: 0.3)).to be(false)
      expect(described_class.monotonic - started).to be_between(0.35, 1.5)
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

  describe ".start_time" do
    it "reads the same start time twice for a running process, and none once it is gone" do
      pid = spawn_group("sleep 31.94")
      first = described_class.start_time(pid)

      expect(first).to be_a(String).and(satisfy { |time| !time.empty? })
      expect(described_class.start_time(pid)).to eq(first)
    ensure
      reap(pid)
      expect(described_class.start_time(pid)).to be_nil if pid
    end

    it "takes /proc/PID/stat's field 22, past a command name with spaces and parentheses" do
      fields = %w[S 1 4242 4242 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 98765 1024]
      expect(described_class.proc_start_time("4242 (a) b (c)) #{fields.join(" ")}\n")).to eq("98765")
    end

    it "reads nothing for a pid chi may not signal" do
      expect(described_class.start_time(0)).to be_nil
      expect(described_class.start_time("12")).to be_nil
    end
  end

  describe ".leader? with the start time chi recorded" do
    it "is a leader when the start time matches, and not when the pid's process started at another time (reused)" do
      pid = spawn_group("sleep 31.95")
      reader = ->(_pid) { "Thu Oct  9 10:00:00 2026" }

      expect(described_class.leader?(pid, started: "Thu Oct  9 10:00:00 2026", start_time: reader)).to be(true)
      expect(described_class.leader?(pid, started: "Wed Oct  8 09:00:00 2026", start_time: reader)).to be(false)
      expect(described_class.leader?(pid, started: described_class.start_time(pid))).to be(true)
    ensure
      reap(pid)
    end

    it "checks only the group when the start time can't be read now (a ps that failed once)" do
      pid = spawn_group("sleep 31.96")

      expect(described_class.leader?(pid, started: "Thu Oct  9 10:00:00 2026", start_time: ->(_pid) {})).to be(true)
    ensure
      reap(pid)
    end

    it "checks only the group without a recorded start time (a record from an older chi)" do
      pid = spawn_group("sleep 31.97")

      expect(described_class.leader?(pid, started: nil, start_time: ->(_pid) { raise "not read" })).to be(true)
    ensure
      reap(pid)
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
      wait_for("the reader to read it") { reader.text == "so far" }

      reader.finish(poll: 0.01, grace: 1)

      expect(reader.done?).to be(true)
      expect(reader.text).to eq("so far")
    ensure
      w.close
    end
  end
end
