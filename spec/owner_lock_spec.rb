# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::OwnerLock do
  let(:dir) { Dir.mktmpdir("owner-lock-spec") }

  after { FileUtils.rm_rf(dir) }

  # Hold the lock in a forked child until the returned writer is closed.
  def hold_in_child(kind: "worker")
    lock_dir = dir # evaluate the let before forking, or the child gets its own
    reader, writer = IO.pipe
    ready_r, ready_w = IO.pipe
    pid = fork do
      writer.close
      ready_r.close
      lock = described_class.acquire(lock_dir, kind: kind, wait: 0)
      ready_w.write(lock ? "ok" : "no")
      ready_w.close
      reader.read # block until the parent closes the writer
      exit!(0)
    end
    reader.close
    ready_w.close
    expect(ready_r.read).to eq("ok")
    ready_r.close
    [pid, writer]
  end

  it "records the owner's pid and kind while held, and nothing once released" do
    lock = described_class.acquire(dir, kind: "tui")

    expect(lock).not_to be_nil
    expect(described_class.owner(dir)).to have_attributes(pid: Process.pid, kind: "tui")

    lock.release
    expect(described_class.owner(dir)).to be_nil
  end

  it "reports no owner when there is no lock file" do
    expect(described_class.owner(dir)).to be_nil
  end

  it "refuses a second owner after waiting, and the probe leaves the holder's lock intact" do
    pid, release = hold_in_child(kind: "worker")

    expect(described_class.acquire(dir, kind: "worker", wait: 0.3)).to be_nil
    expect(described_class.owner(dir)).to have_attributes(pid: pid, kind: "worker")
    # Probing again still sees it held: a probe never releases the owner's lock.
    expect(described_class.owner(dir)).to have_attributes(kind: "worker")

    release.close
    Process.wait(pid)
    expect(described_class.acquire(dir, kind: "worker", wait: 0)).not_to be_nil
  end

  it "conflicts within one process too (a second open file description)" do
    first = described_class.acquire(dir, kind: "tui")
    expect(described_class.acquire(dir, kind: "worker", wait: 0)).to be_nil
    expect(described_class.owner(dir)).to have_attributes(kind: "tui")
    first.release
  end

  it "is not inherited by a detached grandchild that outlives the owner" do
    lock_dir = dir
    grandchild_file = File.join(lock_dir, "grandchild.pid")
    owner = fork do
      described_class.acquire(lock_dir, kind: "worker", wait: 0)
      gc = Process.spawn("sleep", "5", pgroup: true, out: File::NULL, err: File::NULL)
      Process.detach(gc)
      File.write(grandchild_file, gc.to_s)
      exit!(0)
    end
    Process.wait(owner)
    grandchild = File.read(grandchild_file).to_i

    begin
      expect(Process.kill(0, grandchild)).to eq(1) # still running
      expect(described_class.owner(dir)).to be_nil
    ensure
      Process.kill("KILL", grandchild) rescue nil
    end
  end

  describe "a leaving worker (.await_release)" do
    let(:clock) { [100.0] }
    let(:ticks) { [] }

    # A clock the sleeper moves; +on_sleep+ runs at each look.
    def await(on_sleep: nil, **)
      sleeper = lambda do |seconds|
        ticks << seconds
        clock[0] += seconds
        on_sleep&.call(ticks.size)
      end
      described_class.await_release(dir, clock: -> { clock[0] }, sleeper: sleeper, **)
    end

    it "is marked in the lock file, with its leave's budget, and the record kept" do
      lock = described_class.acquire(dir, kind: "worker")
      expect(described_class.owner(dir)).to have_attributes(leaving?: false)

      lock.mark_leaving(wait: 30)

      expect(described_class.owner(dir)).to have_attributes(pid: Process.pid, kind: "worker", leaving?: true, leave_wait: 30.0)
      expect(described_class.owner(dir).leave_left).to be_within(1).of(30)
      lock.release
    end

    it "waits for the release, saying so once" do
      lock = described_class.acquire(dir, kind: "worker")
      lock.mark_leaving(wait: 30)
      seen = []

      result = await(on_wait: ->(owner) { seen << owner.pid }, on_sleep: ->(n) { lock.release if n == 3 })

      expect(result).to eq(:released)
      expect(seen).to eq([Process.pid])
      expect(ticks.size).to eq(3)
    end

    it "gives up after its leave's budget and the margin, still held" do
      lock = described_class.acquire(dir, kind: "worker")
      lock.mark_leaving(wait: 2)

      expect(await(margin: 1, now: -> { Time.now })).to eq(:timeout)
      expect(clock[0] - 100.0).to be_within(described_class::RELEASE_POLL + 0.1).of(3)
      lock.release
    end

    it "returns at once for an owner that isn't leaving, a chi REPL, or none" do
      expect(await).to eq(:not_leaving)
      worker = described_class.acquire(dir, kind: "worker")
      expect(await(on_wait: ->(_) { raise "no line" })).to eq(:not_leaving)
      worker.release
      tui = described_class.acquire(dir, kind: "tui")
      expect(await).to eq(:not_leaving)
      tui.release
      expect(ticks).to be_empty
    end
  end
end
