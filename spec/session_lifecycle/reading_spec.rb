# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require "spec_helper"
require "samagotchi/session_lifecycle"

RSpec.describe Samagotchi::SessionLifecycle do
  def presence(**facts)
    defaults = { session_id: "x", exists: true, owner: nil, stop_marked: false, starting_marked: false, archived: false,
                 link: Samagotchi::WorkerLink::None.new }
    Samagotchi::WorkerPresence.new(**defaults, **facts)
  end

  def owner(kind, **more) = Samagotchi::OwnerLock::Owner.new(pid: 4242, kind: kind, **more)
  def worker = owner("worker")

  def live_link
    sidecar = Samagotchi::WorkerSidecar.new(port: 4567, pid: 4242)
    Samagotchi::WorkerLink::Live.new(sidecar: sidecar, owner: worker)
  end

  def state(**facts) = described_class::Reading.derive(presence(**facts)).state

  it "names its states in precedence order, each once" do
    expect(described_class::STATES).to eq(%i[absent tui_owned deleting stopping skew leaving booting_stuck booting live
                                             stopped_starting stopped archived_starting starting archived idle])
  end

  describe "precedence where states overlap (first wins)" do
    stale = Samagotchi::WorkerLink::Stale.new(sidecar: Samagotchi::WorkerSidecar.new(port: 1), reason: :lock_free)

    it "absent wins over every fact a leftover folder can hold" do
      expect(state(exists: false, owner: worker, stop_marked: true, starting_marked: true, archived: true,
                   link: live_link)).to eq(:absent)
    end

    it "a one-turn run's lock wins over a stop, a start, an archive and a stale sidecar" do
      expect(state(owner: owner("tui"), stop_marked: true, starting_marked: true, archived: true,
                   link: stale)).to eq(:tui_owned)
    end

    it "a deleter's lock wins over a stop (its link reads Starting)" do
      deleting = owner("deleting")
      expect(state(owner: deleting, stop_marked: true,
                   link: Samagotchi::WorkerLink::Starting.new(owner: deleting))).to eq(:deleting)
    end

    it "a worker with a stop is stopping, whatever its link" do
      leaving = owner("worker", leaving_at: Time.now.iso8601)
      links = [live_link, Samagotchi::WorkerLink::Starting.new(owner: worker),
               Samagotchi::WorkerLink::Starting.new(owner: worker, stuck: true),
               Samagotchi::WorkerLink::Leaving.new(owner: leaving),
               Samagotchi::WorkerLink::Skew.new(sidecar: live_link.sidecar, owner: worker, reason: :protocol)]
      expect(links.map { |link| state(owner: worker, stop_marked: true, link: link) }).to all(eq(:stopping))
    end

    it "a worker's link names its state over a start or an archive" do
      skew = Samagotchi::WorkerLink::Skew.new(sidecar: live_link.sidecar, owner: worker, reason: :protocol)
      both = { starting_marked: true, archived: true }
      expect(state(owner: worker, link: skew, **both)).to eq(:skew)
      expect(state(owner: worker, link: Samagotchi::WorkerLink::Leaving.new(owner: worker), **both)).to eq(:leaving)
      expect(state(owner: worker, link: Samagotchi::WorkerLink::Starting.new(owner: worker, stuck: true), **both))
        .to eq(:booting_stuck)
      expect(state(owner: worker, link: Samagotchi::WorkerLink::Starting.new(owner: worker), **both)).to eq(:booting)
      expect(state(owner: worker, link: live_link, **both)).to eq(:live)
    end

    it "an owner of unknown kind (a blank lock record) is booting, even with a stop" do
      blank = Samagotchi::OwnerLock::Owner.new
      expect(state(owner: blank, stop_marked: true,
                   link: Samagotchi::WorkerLink::Starting.new(owner: blank))).to eq(:booting)
    end

    it "with no owner: a stop over an archive, a start beside either makes the compound state" do
      expect(state(stop_marked: true, starting_marked: true, archived: true)).to eq(:stopped_starting)
      expect(state(stop_marked: true, archived: true)).to eq(:stopped)
      expect(state(starting_marked: true, archived: true)).to eq(:archived_starting)
      expect(state(starting_marked: true)).to eq(:starting)
      expect(state(archived: true)).to eq(:archived)
      expect(state).to eq(:idle)
    end

    it "a stale sidecar stays a fact, not a state" do
      expect(state(link: stale)).to eq(:idle)
      expect(state(link: stale, stop_marked: true)).to eq(:stopped)
    end
  end

  describe "CANONICAL" do
    it "holds one presence per state that derives back to it" do
      expect(described_class::CANONICAL.keys).to eq(described_class::STATES)
      described_class::CANONICAL.each do |name, facts|
        expect(described_class::Reading.derive(facts).state).to eq(name), "CANONICAL[#{name.inspect}]"
      end
    end

    it "takes the decided canonical facts for the compound states" do
      stopping = described_class::CANONICAL.fetch(:stopping)
      expect([stopping.owner.kind, stopping.link.class, stopping.stop_marked?])
        .to eq(["worker", Samagotchi::WorkerLink::Live, true])
      expect(described_class::CANONICAL.fetch(:stopped_starting).to_h.slice(:stop_marked, :starting_marked, :archived))
        .to eq(stop_marked: true, starting_marked: true, archived: false)
    end
  end

  describe ".read" do
    let(:state_dir) { Dir.mktmpdir("session-lifecycle") }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: state_dir)
      end
    end
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }

    after { FileUtils.rm_rf(state_dir) }

    it "reads an idle session from its files, with no successor" do
      reading = described_class.read(session.id, state_dir: state_dir)

      expect(reading.state).to eq(:idle)
      expect(reading.facts).to be(reading.presence)
      expect(reading.presence.link).to be_a(Samagotchi::WorkerLink::None)
      expect(reading).not_to be_continuing
    end

    it "is absent for an id with no file, and for a string that is no id" do
      expect(described_class.read(SecureRandom.uuid, state_dir: state_dir).state).to eq(:absent)
      expect(described_class.read("../nope", state_dir: state_dir).state).to eq(:absent)
    end

    it "reads the stop, starting and archived markers" do
      Samagotchi::StartingMarker.mark(session.id, state_dir: state_dir)
      Samagotchi::Session.mark_stopped(session.id, state_dir: state_dir, now: Time.now)
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)

      expect(described_class.read(session.id, state_dir: state_dir).state).to eq(:stopped_starting)
    end

    it "takes the owner as read by the caller" do
      tui = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui")

      expect(described_class.read(session.id, state_dir: state_dir, owner: tui).state).to eq(:tui_owned)
    end

    it "leaves a stale sidecar on disk (a look, never an unlink)" do
      Samagotchi::WorkerSidecar.new(port: 4567, pid: 4242).write(dir)

      reading = described_class.read(session.id, state_dir: state_dir)

      expect(reading.presence.link).to be_a(Samagotchi::WorkerLink::Stale)
      expect(File).to exist(Samagotchi::WorkerSidecar.path(dir))
    end

    it "asks for a continue in flight once, and keeps its successor as a fact" do
      successor = SecureRandom.uuid
      allow(Samagotchi::ContinueIntent).to receive(:in_flight).and_return(successor)

      reading = described_class.read(session.id, state_dir: state_dir)

      expect(Samagotchi::ContinueIntent).to have_received(:in_flight).once.with(session.id, state_dir: state_dir)
      expect(reading.continuing).to eq(successor)
      expect(reading).to be_continuing
      expect(reading.state).to eq(:idle)
    end
  end
end
