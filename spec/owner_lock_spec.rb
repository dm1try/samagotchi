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
    expect(described_class.owner(dir)).to include("pid" => Process.pid, "kind" => "tui")

    lock.release
    expect(described_class.owner(dir)).to be_nil
  end

  it "reports no owner when there is no lock file" do
    expect(described_class.owner(dir)).to be_nil
    expect(described_class.lock_file?(dir)).to be false
  end

  it "refuses a second owner after waiting, and the probe leaves the holder's lock intact" do
    pid, release = hold_in_child(kind: "worker")

    expect(described_class.acquire(dir, kind: "worker", wait: 0.3)).to be_nil
    expect(described_class.owner(dir)).to include("pid" => pid, "kind" => "worker")
    # Probing again still sees it held: a probe never releases the owner's lock.
    expect(described_class.owner(dir)).to include("kind" => "worker")

    release.close
    Process.wait(pid)
    expect(described_class.acquire(dir, kind: "worker", wait: 0)).not_to be_nil
  end

  it "conflicts within one process too (a second open file description)" do
    first = described_class.acquire(dir, kind: "tui")
    expect(described_class.acquire(dir, kind: "worker", wait: 0)).to be_nil
    expect(described_class.owner(dir)).to include("kind" => "tui")
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
end
