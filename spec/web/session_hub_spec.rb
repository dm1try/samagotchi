# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"

require "samagotchi/web/session_hub"
require "samagotchi/session"
require "samagotchi/owner_lock"

# The hub keeps chi web's one projection of the session list, fed by a scan
# over the state dir, and tells its subscribers what changed. Files stay
# the source of truth; the specs drive #scan by hand, as a tick would.
RSpec.describe Samagotchi::Web::SessionHub do
  let(:root) { Dir.mktmpdir("session-hub-spec") }
  let(:state_dir) { File.join(root, "sessions") }
  let(:hub) { described_class.new(state_dir: state_dir) }
  let(:events) { [] }

  before { hub.subscribe(->(event) { events << event }) }
  after { FileUtils.rm_rf(root) }

  def save_session(prompt: "hi", working_directory: "/tmp/proj", project_root: :from_dir, status: "idle")
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: working_directory).tap do |s|
      s.last_prompt = prompt
      s.status = status
      s.project_root = project_root unless project_root == :from_dir
      s.save(state_dir: state_dir)
    end
  end

  # Session#save stamps updated_at with now (and two sessions made in the
  # same millisecond share a created_at); the file is edited to say otherwise.
  def backdate(session, time)
    path = File.join(state_dir, "#{session.id}.json")
    data = JSON.parse(File.read(path))
    data["updated_at"] = data["created_at"] = time.iso8601(3)
    File.write("#{path}.tmp", JSON.generate(data))
    File.rename("#{path}.tmp", path)
  end

  def session_dir(session)
    Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
  end

  def types
    events.map(&:type)
  end

  describe "#scan" do
    it "builds the projection from the files on the first scan and tells subscribers of each session" do
      a = save_session(prompt: "first")
      b = save_session(prompt: "second")

      hub.scan

      expect(hub.snapshot.map { |s| s[:id] }).to contain_exactly(a.id, b.id)
      expect(types).to eq(%w[session session])
      expect(events.map { |e| e.data[:session][:last_prompt] }).to contain_exactly("first", "second")
      expect(events.map(&:seq)).to eq([1, 2])
    end

    it "emits one session event for a new file, and nothing for a tick with no change" do
      hub.scan
      a = save_session
      hub.scan
      hub.scan

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(id: a.id, owner: nil, bridge_up: false, status: "idle")
    end

    it "emits the new last_prompt and updated_at when a session file changes" do
      a = save_session(prompt: "before")
      hub.scan
      events.clear
      a.last_prompt = "after"
      a.updated_at = (Time.now + 5).iso8601(3)
      a.save(state_dir: state_dir)

      hub.scan

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(last_prompt: "after", updated_at: a.updated_at)
      expect(hub.snapshot.first[:last_prompt]).to eq("after")
    end

    it "emits session_gone for a deleted file and drops it from the projection" do
      a = save_session
      hub.scan
      events.clear
      File.delete(File.join(state_dir, "#{a.id}.json"))

      hub.scan

      expect(types).to eq(%w[session_gone])
      expect(events.first.data).to eq(id: a.id)
      expect(hub.snapshot).to eq([])
    end

    it "leaves a corrupt file out, as Session.list does" do
      a = save_session
      File.write(File.join(state_dir, "corrupt.json"), "{ invalid")

      hub.scan

      expect(hub.snapshot.map { |s| s[:id] }).to eq([a.id])
      expect(types).to eq(%w[session])
    end

    it "emits the recap preview once recap.json is written into the session's folder" do
      a = save_session
      hub.scan
      events.clear
      FileUtils.mkdir_p(session_dir(a))
      File.write(File.join(session_dir(a), "recap.json"), JSON.generate(text: "We fixed the login. Then the tests.", covered: 2))

      hub.scan

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(id: a.id, recap: "We fixed the login.")
    end

    it "is an empty projection without a state dir, and fills in when the dir appears" do
      hub.scan

      expect(hub.snapshot).to eq([])
      expect(events).to eq([])

      a = save_session
      hub.scan

      expect(hub.snapshot.map { |s| s[:id] }).to eq([a.id])
    end

    it "keeps delivering to the other subscribers when one raises" do
      hub.subscribe(->(_event) { raise "boom" })
      seen = []
      hub.subscribe(->(event) { seen << event.type })
      save_session

      expect { hub.scan }.not_to raise_error
      expect(seen).to eq(%w[session])
      expect(types).to eq(%w[session])
    end

    it "stops delivering to a subscriber that unsubscribed" do
      seen = []
      handle = hub.subscribe(->(event) { seen << event.type })
      save_session
      hub.scan
      handle.unsubscribe
      save_session
      hub.scan

      expect(seen).to eq(%w[session])
      expect(types).to eq(%w[session session])
    end
  end

  describe "#touch" do
    it "rescans one session right away and emits its change without a tick" do
      a = save_session(prompt: "before")
      hub.scan
      events.clear
      a.last_prompt = "after"
      a.save(state_dir: state_dir)

      hub.touch(a.id)

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(id: a.id, last_prompt: "after")
    end

    it "emits session_gone for a session whose file went, and nothing for an id it never knew" do
      a = save_session
      hub.scan
      events.clear
      File.delete(File.join(state_dir, "#{a.id}.json"))

      hub.touch(a.id)
      hub.touch("never-seen")

      expect(types).to eq(%w[session_gone])
    end

    it "picks up a session the tick hasn't seen yet (the page's own create)" do
      hub.scan
      a = save_session

      hub.touch(a.id)

      expect(types).to eq(%w[session])
      expect(hub.snapshot.map { |s| s[:id] }).to eq([a.id])
    end
  end

  describe "#snapshot" do
    it "sorts by updated_at desc like Session.list, and takes sort and order" do
      old = save_session(prompt: "old")
      new = save_session(prompt: "new")
      backdate(old, Time.now - 60)
      hub.scan

      expect(hub.snapshot.map { |s| s[:last_prompt] }).to eq(%w[new old])
      expect(hub.snapshot(sort: "updated_at", order: "asc").map { |s| s[:last_prompt] }).to eq(%w[old new])
      expect(hub.snapshot(sort: "created_at", order: "asc").map { |s| s[:id] }).to eq([old.id, new.id])
    end

    it "filters by project root, taking an old session's project from its working directory, and no filter for a nil root" do
      mine = save_session(project_root: "/repo/mine")
      other = save_session(project_root: "/repo/other")
      old = save_session(working_directory: File.expand_path("../..", __dir__), project_root: nil)
      hub.scan

      expect(hub.snapshot(project_root: "/repo/mine").map { |s| s[:id] }).to eq([mine.id])
      expect(hub.snapshot(project_root: old.project_root).map { |s| s[:id] }).to eq([old.id])
      expect(hub.snapshot.map { |s| s[:id] }).to contain_exactly(mine.id, other.id, old.id)
    end

    it "is the same list Session.list gives, in the same order" do
      3.times { |i| save_session(prompt: "p#{i}") }
      hub.scan

      expect(hub.snapshot.map { |s| s[:id] }).to eq(Samagotchi::Session.list(state_dir: state_dir).map(&:id))
    end
  end

  describe "liveness" do
    let(:clock) { [0.0] }
    let(:hub) { described_class.new(state_dir: state_dir, now: -> { clock.first }) }

    def lock_dir(session)
      session_dir(session)
    end

    def acquire(session, kind: "worker")
      Samagotchi::OwnerLock.acquire(lock_dir(session), kind: kind, wait: 0)
    end

    it "sees an owner take the session, then its bridge come up: two events, the page acts on the second" do
      a = save_session(status: "idle")
      hub.scan
      events.clear

      lock = acquire(a)
      hub.scan
      expect(types).to eq(%w[session])
      expect(events.last.data[:session]).to include(owner: "worker", status: "idle", bridge_up: false)

      File.write(File.join(lock_dir(a), "bridge.json"), JSON.generate(port: 4321, started_at: Time.now.iso8601(3)))
      hub.scan
      expect(types).to eq(%w[session session])
      expect(events.last.data[:session]).to include(owner: "worker", bridge_up: true)
    ensure
      lock&.release
    end

    it "sees the owner go, on the next tick, with no file change: owner nil, bridge_up false, a 'running' shown idle" do
      a = save_session(status: "running")
      lock = acquire(a)
      File.write(File.join(lock_dir(a), "bridge.json"), JSON.generate(port: 4321))
      hub.scan
      expect(hub.snapshot.first).to include(owner: "worker", status: "running", bridge_up: true)
      events.clear

      lock.release
      hub.scan
      hub.scan

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(owner: nil, bridge_up: false, status: "idle")
    end

    it "treats a new worker for the same session as a change, even though owner reads worker both times" do
      a = save_session
      lock = acquire(a)
      hub.scan
      events.clear

      # The lock file holds the owner's pid; a replacement worker writes its own.
      File.write(Samagotchi::OwnerLock.path(lock_dir(a)), JSON.generate(pid: Process.pid + 100_000, kind: "worker"))
      hub.scan

      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(owner: "worker")
    ensure
      lock&.release
    end

    it "probes an unowned session only every full-probe interval: a tui on an old lock file shows up within it" do
      a = save_session
      acquire(a).release # the lock file exists from before; taking it again leaves no file signal
      hub.scan
      events.clear

      lock = acquire(a, kind: "tui")
      clock[0] += 1.0
      hub.scan
      expect(types).to eq([])

      clock[0] += described_class::FULL_PROBE_INTERVAL
      hub.scan
      expect(types).to eq(%w[session])
      expect(events.first.data[:session]).to include(owner: "tui")
    ensure
      lock&.release
    end

    it "probes in touch whatever the clock says" do
      a = save_session
      acquire(a).release
      hub.scan
      events.clear
      lock = acquire(a, kind: "tui")

      hub.touch(a.id)

      expect(events.last.data[:session]).to include(owner: "tui")
    ensure
      lock&.release
    end

    it "runs the retention sweep on the full-probe tick" do
      manager = double("manager", session_owner: nil)
      hub = described_class.new(state_dir: state_dir, manager: manager, now: -> { clock.first })
      FileUtils.mkdir_p(state_dir)

      expect(manager).to receive(:retention_sweep_if_due).with(state_dir: state_dir).twice
      hub.scan
      clock[0] += 1.0
      hub.scan
      clock[0] += described_class::FULL_PROBE_INTERVAL
      hub.scan
    end
  end

  describe "the tick thread" do
    it "scans on its own once started, and stops when told" do
      hub = described_class.new(state_dir: state_dir, scan_interval: 0.01)
      seen = Queue.new
      hub.subscribe(->(event) { seen << event.type })
      hub.start
      hub.start
      a = save_session

      expect(seen.pop(timeout: 2)).to eq("session")
      hub.stop
      expect(hub).to be_stopped
      File.delete(File.join(state_dir, "#{a.id}.json"))
      sleep 0.05
      expect(seen).to be_empty
    end

    it "logs a tick that raises and keeps going" do
      dir = Dir.mktmpdir
      Samagotchi::Log.configure(path: File.join(dir, "chi.log"))
      hub = described_class.new(state_dir: state_dir, scan_interval: 0.01)
      calls = Queue.new
      allow(hub).to receive(:scan) do
        calls << 1
        raise "boom" if calls.size == 1
      end

      hub.start
      3.times { calls.pop(timeout: 2) }
      hub.stop

      records = File.open(File.join(dir, "chi.log")) { |io| Samagotchi::LogLine.each_record(io).to_a }
      expect(records.map { |r| [r.tag, r.event, r.fields["error"]] }).to include(["web", "hub_scan_failed", "RuntimeError"])
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "#subscribe" do
    it "hands the subscriber the snapshot as the same step, so no stale event can follow it" do
      a = save_session
      hub.scan

      handle, snapshot = hub.subscribe(->(_e) {}, snapshot: true)

      expect(snapshot.map { |s| s[:id] }).to eq([a.id])
      expect(handle).to respond_to(:unsubscribe)
    end
  end
end
