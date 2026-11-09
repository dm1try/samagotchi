# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_presence"
require_relative "support/worker_fixtures"

RSpec.describe Samagotchi::WorkerPresence do
  include WorkerFixtures

  let(:state_dir) { Dir.mktmpdir("worker-presence") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
      s.status = Samagotchi::Session::STATUS_IDLE
      s.save(state_dir: state_dir)
    end
  end
  let(:id) { session.id }
  let(:dir) { Samagotchi::Session.session_dir(id, state_dir: state_dir) }

  after { FileUtils.rm_rf(state_dir) }

  def read(**opts) = described_class.read(id, state_dir: state_dir, **opts)

  describe ".read" do
    it "reads a saved session with nothing on it as there, unowned and unmarked" do
      expect(read).to have_attributes(session_id: id, exists?: true, owned?: false, tui_owned?: false, stop_marked?: false,
                                      starting?: false, start_pending?: false, archived?: false, link: nil,
                                      turn_status: nil, scratch: nil)
    end

    it "reads a missing session as not there" do
      presence = described_class.read(SecureRandom.uuid, state_dir: state_dir)

      expect(presence).to have_attributes(exists?: false, owned?: false, stop_marked?: false, archived?: false)
      expect(presence.wake_refusal).to eq(:gone)
    end

    it "reads an id that isn't one as not there, reading nothing" do
      expect(Samagotchi::OwnerLock).not_to receive(:owner)
      presence = described_class.read("../bogus", state_dir: state_dir, link: :unlink)

      expect(presence).to have_attributes(exists?: false, owned?: false, link: Samagotchi::WorkerLink::None.new)
      expect(presence.wake_refusal).to eq(:gone)
      expect(described_class.read(nil, state_dir: state_dir).link).to be_nil
    end

    it "reads the owner lock's holder" do
      hold_worker(dir)

      expect(read.owner).to have_attributes(kind: "worker", pid: Process.pid)
      expect(read).to have_attributes(owned?: true, tui_owned?: false)
    end

    it "reads a one-turn chi run's lock as tui-owned" do
      hold_worker(dir, kind: "tui")

      expect(read).to have_attributes(owned?: true, tui_owned?: true)
    end

    it "takes an owner the caller read already, without reading the lock" do
      owner = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui", started_at: nil)
      expect(Samagotchi::OwnerLock).not_to receive(:owner)

      expect(read(owner: owner)).to have_attributes(owner: owner, tui_owned?: true)
      expect(read(owner: nil)).to have_attributes(owned?: false)
    end

    it "calls an owner reader for a valid id only" do
      owner = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil)

      expect(read(owner: -> { owner })).to have_attributes(owner: owner, owned?: true)
      expect(described_class.read("../x", state_dir: state_dir, owner: -> { raise "read" })).to have_attributes(exists?: false)
    end

    it "reads the stop marker" do
      Samagotchi::Session.mark_stopped(id, state_dir: state_dir)

      expect(read).to have_attributes(stop_marked?: true)
    end

    it "reads a fresh starting marker, and not a stale one" do
      Samagotchi::StartingMarker.mark(id, state_dir: state_dir)
      expect(read).to have_attributes(starting?: true, resume_held_off?: true)

      File.write(File.join(dir, Samagotchi::StartingMarker::FILE), JSON.generate({ "pid" => Process.pid, "at" => (Time.now - 120).iso8601(3) }))
      expect(read).to have_attributes(starting?: false, resume_held_off?: false)
    end

    it "reads the archive marker" do
      Samagotchi::ArchiveStore.archive(id, state_dir: state_dir)

      expect(read).to have_attributes(archived?: true)
    end

    it "asks the injected spawn reader, with the id and state dir" do
      asked = []
      presence = read(spawned: lambda { |sid, sd|
        asked << [sid, sd]
        true
      })

      expect(asked).to eq([[id, state_dir]])
      expect(presence).to have_attributes(spawned_here: true, start_pending?: true, resume_held_off?: true)
    end

    it "resolves the link only when asked, looking or unlinking a stale sidecar" do
      Samagotchi::WorkerSidecar.new(port: 5001, pid: 4242).write(dir)
      sidecar = Samagotchi::WorkerSidecar.path(dir)

      expect(read.link).to be_nil
      expect(read(link: :look).link).to be_a(Samagotchi::WorkerLink::Stale)
      expect(File.exist?(sidecar)).to be(true)
      expect(read(link: :unlink).link).to be_a(Samagotchi::WorkerLink::Stale)
      expect(File.exist?(sidecar)).to be(false)
    end

    it "resolves a live worker's link with the owner it read, reading the lock once" do
      live_sidecar_fixture(dir, port: 5001)
      allow(Samagotchi::OwnerLock).to receive(:owner).and_call_original

      presence = read(link: :look)
      expect(presence.link).to be_a(Samagotchi::WorkerLink::Live)
      expect(presence).to have_attributes(live?: true, worker_owned?: true, owned?: true)
      expect(presence.link.owner).to eq(presence.owner)
      expect(Samagotchi::OwnerLock).to have_received(:owner).once
    end

    it "resolves the link with the owner the caller read" do
      owner = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: Time.now.iso8601)

      presence = read(owner: owner, link: :look)
      expect(presence.link).to eq(Samagotchi::WorkerLink::Starting.new(owner: owner, stuck: false))
      expect(presence).to have_attributes(live?: false, worker_owned?: true)
    end
  end

  describe ".stop_marked?" do
    it "reads the stop marker alone" do
      expect(Samagotchi::OwnerLock).not_to receive(:owner)
      expect(Samagotchi::StartingMarker).not_to receive(:fresh?)
      expect(described_class.stop_marked?(id, state_dir: state_dir)).to be(false)

      Samagotchi::Session.mark_stopped(id, state_dir: state_dir)
      expect(described_class.stop_marked?(id, state_dir: state_dir)).to be(true)
      expect(described_class.stop_marked?("../x", state_dir: state_dir)).to be(false)
    end
  end

  describe "#with_session" do
    it "adds the loaded session's status and scratch flag" do
      presence = read.with_session(session)
      expect(presence).to have_attributes(turn_status: "idle", turn_stopped?: false, scratch?: false)

      session.status = Samagotchi::Session::STATUS_STOPPED
      session.scratch = true
      expect(read.with_session(session)).to have_attributes(turn_stopped?: true, scratch?: true)
    end

    it "keeps the turn status apart from the stop marker" do
      Samagotchi::Session.mark_stopped(id, state_dir: state_dir)

      expect(read).to have_attributes(stop_marked?: true, turn_stopped?: false)
      loaded = read.with_session(Samagotchi::Session.load(id, state_dir: state_dir))
      expect(loaded).to have_attributes(stop_marked?: true, turn_stopped?: true)
    end
  end

  describe "#start_pending?" do
    it "is false once a stop came, though this process spawned one" do
      Samagotchi::Session.mark_stopped(id, state_dir: state_dir)

      expect(read(spawned: ->(*) { true })).to have_attributes(spawned_here: true, start_pending?: false,
                                                               resume_held_off?: false)
    end
  end

  describe "#wake_refusal" do
    def presence(**facts)
      described_class.new(session_id: "s", exists: true, owner: nil, stop_marked: false, starting_marked: false,
                          spawned_here: false, archived: false, **facts)
    end

    let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }

    it "answers in its order: gone, owned, the stop marker, archived, starting" do
      expect(presence(exists: false, owner: worker).wake_refusal).to eq(:gone)
      expect(presence(owner: worker, stop_marked: true).wake_refusal).to eq(:owned)
      expect(presence(stop_marked: true, archived: true).wake_refusal).to eq(:stopped)
      expect(presence(archived: true, starting_marked: true).wake_refusal).to eq(:archived)
      expect(presence(starting_marked: true).wake_refusal).to eq(:starting)
      expect(presence.wake_refusal).to be_nil
    end

    it "leaves the in-process spawn to resume_session" do
      expect(presence(spawned_here: true).wake_refusal).to be_nil
    end

    it "answers the session's own fields after: the turn status, then scratch" do
      expect(presence(turn_status: "stopped", scratch: true).wake_refusal_by_session).to eq(:stopped)
      expect(presence(turn_status: "idle", scratch: true).wake_refusal_by_session).to eq(:scratch)
      expect(presence(turn_status: "idle", scratch: false).wake_refusal_by_session).to be_nil
    end
  end

  describe "#live? and #worker_owned?" do
    it "are false when the link wasn't read" do
      hold_worker(dir)

      expect(read).to have_attributes(owned?: true, live?: false, worker_owned?: false)
    end

    it "is worker-owned but not live while a worker has no Bridge yet" do
      hold_worker(dir)

      expect(read(link: :look)).to have_attributes(live?: false, worker_owned?: true)
    end
  end
end
