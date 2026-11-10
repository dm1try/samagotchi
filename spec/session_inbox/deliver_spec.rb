# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/session_manager"
require "samagotchi/archive_store"
require "samagotchi/owner_lock"

# SessionInbox.deliver: resolve, refuse, write, one presence read, wake.
RSpec.describe "SessionInbox.deliver" do
  let(:tmpdir) { Dir.mktmpdir("inbox-deliver") }
  let(:session) { make }
  let(:starts) { [] }
  let(:start) { ->(id) { (starts << id) && :woken } }
  let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }
  let(:tui) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "tui", started_at: nil) }

  after { FileUtils.rm_rf(tmpdir) }

  def make(continues: nil, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: continues).tap do |s|
      s.scratch = scratch
      s.save(state_dir: tmpdir)
    end
  end

  def deliver(kind, id = session.id, owner: ->(_) {}, asks: true, **, &write)
    written = []
    write ||= ->(at) { (written << at) && asks }
    result = Samagotchi::SessionInbox.deliver(kind, id, state_dir: tmpdir, owner: owner, start: start, **, &write)
    [result, written]
  end

  it "writes under the target and starts a worker for an idle session" do
    result, written = deliver(:ring)

    expect(written).to eq([session.id])
    expect(starts).to eq([session.id])
    expect(result).to have_attributes(kind: :ring, id: session.id, asked: session.id, via: :same, status: :queued,
                                      wake: :woken, queued: nil)
  end

  it "starts none when the write asks for none, or the caller allows none" do
    result, written = deliver(:push, asks: false)
    expect([result.wake, result.status, written]).to eq([:off, :waits, [session.id]])

    result, = deliver(:ring, wake: false)
    expect(result.wake).to eq(:off)
    expect(starts).to be_empty
  end

  it "leaves a session a worker holds to it, and a stopped one waiting" do
    result, = deliver(:ring, owner: ->(_) { worker })
    expect(result).to have_attributes(status: :queued, wake: :live)

    Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
    result, written = deliver(:push)
    expect(result).to have_attributes(status: :waits, wake: :stopped)
    expect(written).to eq([session.id])
    expect(starts).to be_empty
  end

  it "refuses before writing: a gone session, and a note to a one-turn run's or a scratch session" do
    result, written = deliver(:ring, SecureRandom.uuid)
    expect([result.status, result.wake, written]).to eq([:refused, :gone, []])

    result, written = deliver(:note, owner: ->(_) { tui })
    expect([result.refused?, result.wake, written]).to eq([true, :owned, []])

    result, written = deliver(:note, make(scratch: true).id)
    expect([result.refused?, result.wake, written]).to eq([true, :scratch, []])

    result, written = deliver(:ring, make(scratch: true).id)
    expect([result.status, result.wake, written.size]).to eq([:waits, :scratch, 1])
    expect(starts).to be_empty
  end

  it "keeps a ring's file with the archived parent and wakes the link that reads it" do
    Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)
    link = make(continues: session.id)

    result, written = deliver(:ring)

    expect(written).to eq([session.id])
    expect(starts).to eq([link.id])
    expect(result).to have_attributes(id: link.id, asked: session.id, via: :head, wake: :woken)
  end

  it "reads the owner through the caller's reader, with the id it decides on" do
    asked = []
    expect(Samagotchi::OwnerLock).not_to receive(:owner)

    deliver(:ring, owner: ->(id) { (asked << id) && nil })

    expect(asked).to eq([session.id])
  end

  it "starts through SessionManager.start_for_inbox, logged as the kind's event, by default" do
    allow(Samagotchi::SessionManager).to receive(:start_for_inbox).and_return(:woken)

    result = Samagotchi::SessionInbox.deliver(:push, session.id, state_dir: tmpdir) { true }

    expect(result.wake).to eq(:woken)
    expect(Samagotchi::SessionManager).to have_received(:start_for_inbox)
      .with(session.id, state_dir: tmpdir, event: :context_woke_session)
  end

  describe "SessionManager.start_for_inbox" do
    before { allow(Process).to receive(:spawn) }

    def start_for(id) = Samagotchi::SessionManager.start_for_inbox(id, state_dir: tmpdir, event: :context_woke_session)

    it "says :starting, not :woken, when another start won the claim, and logs no wake" do
      allow(Samagotchi::StartingMarker).to receive(:claim).and_return(false)
      expect(Samagotchi::Log).not_to receive(:info).with(:worker, :context_woke_session, anything)

      expect(start_for(session.id)).to eq(:starting)
      result = Samagotchi::SessionInbox.deliver(:push, session.id, state_dir: tmpdir) { true }
      expect(result).to have_attributes(status: :queued, wake: :starting)
      expect(Process).not_to have_received(:spawn)
    end

    it "says :live when a worker took the lock between the read and the claim" do
      allow(Samagotchi::SessionManager).to receive(:session_owner).and_return(nil, worker)

      expect(start_for(session.id)).to eq(:live)
      expect(Process).not_to have_received(:spawn)
    end

    it "says :woken when it spawned the worker" do
      allow(Process).to receive(:spawn).and_return(999_999)
      allow(Process).to receive(:waitpid).and_raise(Errno::ECHILD)

      expect(start_for(session.id)).to eq(:woken)
      expect(Process).to have_received(:spawn).once
    end
  end

  it "wakes without a write (SessionInbox.wake)" do
    result = Samagotchi::SessionInbox.wake(:ring, session.id, state_dir: tmpdir, owner: ->(_) {}, start: start)

    expect(result).to have_attributes(status: :queued, wake: :woken)
    expect(starts).to eq([session.id])
  end
end
