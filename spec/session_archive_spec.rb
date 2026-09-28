# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/session_manager"
require "samagotchi/archive_store"
require "samagotchi/owner_lock"

RSpec.describe "Session archive" do
  let(:tmpdir) { Dir.mktmpdir("session-archive") }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(days_old: 0, parent: nil, status: nil, scratch: false, owner: nil)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                              parent_id: parent&.id, scratch: scratch)
    session.first_preview = "a task"
    session.status = status if status
    session.save(state_dir: tmpdir)
    if days_old.positive?
      path = File.join(tmpdir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = data["created_at"] = (Time.now - days_old * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
    end
    locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: owner) if owner
    session
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)

  def archived?(session) = Samagotchi::ArchiveStore.archived?(dir_of(session))

  def archive!(session) = Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)

  def ids(sessions) = sessions.map(&:id)

  describe Samagotchi::ArchiveStore do
    it "writes the marker next to the session, and unarchive keeps when" do
      session = make
      expect(archive!(session)).to be(true)
      expect(archived?(session)).to be(true)
      expect(JSON.parse(File.read(File.join(dir_of(session), "archived")))).to have_key("archived_at")

      expect(described_class.unarchive(session.id, state_dir: tmpdir)).to be(true)
      expect(archived?(session)).to be(false)
      expect(described_class.unarchived_at(dir_of(session))).to be_within(5).of(Time.now)
      expect(described_class.unarchive(session.id, state_dir: tmpdir)).to be(false)
    end

    it "never recreates a deleted session's dir" do
      session = make
      Samagotchi::SessionManager.delete_session(session.id, state_dir: tmpdir)

      expect(archive!(session)).to be(false)
      expect(Dir.exist?(dir_of(session))).to be(false)
    end

    it "counts a human's input only: web, tui, chi send and no client id" do
      expect(%w[web:ab12 tui:4242 cli:send].map { |id| described_class.user_input?(id) }).to all(be(true))
      expect(described_class.user_input?(nil)).to be(true)
      expect(%w[delegate:1234abcd plugin system:reminder].map { |id| described_class.user_input?(id) }).to all(be(false))
    end
  end

  describe "the lists" do
    it "leave archived sessions out of Session.list and the summaries unless asked" do
      kept = make
      hidden = make
      archive!(hidden)

      expect(ids(Samagotchi::Session.list(state_dir: tmpdir))).to eq([kept.id])
      all = Samagotchi::Session.list(state_dir: tmpdir, include_archived: true)
      expect(all.to_h { |s| [s.id, s.archived] }).to eq(kept.id => false, hidden.id => true)

      summaries = Samagotchi::SessionManager.session_summaries(state_dir: tmpdir)
      expect(summaries.map { |s| s[:id] }).to eq([kept.id])
      with = Samagotchi::SessionManager.session_summaries(state_dir: tmpdir, include_archived: true)
      expect(with.find { |s| s[:id] == hidden.id }).to include(archived: true)
    end

    it "keeps archived children in children_of (max_children, delegate_result)" do
      parent = make
      child = make(parent: parent)
      archive!(child)

      expect(Samagotchi::SessionManager.children_of(parent.id, state_dir: tmpdir).map { |s| s[:id] }).to eq([child.id])
    end
  end

  describe "retention" do
    it "neither deletes nor counts an archived session" do
      old = make(days_old: 30)
      archive!(old)
      recent = make(days_old: 1)
      newest = make

      result = Samagotchi::Session.prune(state_dir: tmpdir, days: 14, max_count: 2)

      expect(result[:deleted]).to eq([])
      expect(File.exist?(File.join(tmpdir, "#{old.id}.json"))).to be(true)
      expect(result[:kept]).to contain_exactly(recent.id, newest.id)
    end

    it "keeps an archived session through `--days 0` and the any-age clean" do
      archived = make(days_old: 30)
      archive!(archived)

      expect(Samagotchi::Session.prune(state_dir: tmpdir, days: 0, max_count: 0, any_age: true)[:deleted]).to eq([])
      expect(Samagotchi::Session.exist?(archived.id, state_dir: tmpdir)).to be(true)
    end

    it "ages an unarchived session from when it was unarchived" do
      old = make(days_old: 30)
      archive!(old)
      Samagotchi::ArchiveStore.unarchive(old.id, state_dir: tmpdir)
      stale = make(days_old: 30)

      result = Samagotchi::Session.prune(state_dir: tmpdir, days: 14, max_count: 500)

      expect(result[:deleted]).to eq([stale.id])
      expect(result[:kept]).to eq([old.id])
    end
  end

  describe "SessionManager.archive_session / unarchive_session" do
    it "archives the session and its delegates, and unarchive brings them all back" do
      parent = make
      child = make(parent: parent)
      other = make

      result = Samagotchi::SessionManager.archive_session(parent.id[0, 8], state_dir: tmpdir)

      expect(result).to include(id: parent.id, stopped: [], discarded: [])
      expect(result[:archived]).to contain_exactly(parent.id, child.id)
      expect([archived?(parent), archived?(child), archived?(other)]).to eq([true, true, false])

      back = Samagotchi::SessionManager.unarchive_session(parent.id, state_dir: tmpdir)
      expect(back[:unarchived]).to contain_exactly(parent.id, child.id)
      expect([archived?(parent), archived?(child)]).to eq([false, false])
    end

    it "stops a live idle worker first" do
      live = make(owner: "worker")
      allow(Samagotchi::SessionManager).to receive(:stop_session) do |id, **|
        locks.each(&:release)
        Samagotchi::Session.mark_stopped(id, state_dir: tmpdir)
        true
      end

      result = Samagotchi::SessionManager.archive_session(live.id, state_dir: tmpdir)

      expect(Samagotchi::SessionManager).to have_received(:stop_session).with(live.id, state_dir: tmpdir, wait: 5)
      expect(result).to include(archived: [live.id], stopped: [live.id])
      expect(archived?(live)).to be(true)
    end

    it "refuses while a turn runs in it" do
      busy = make(owner: "worker", status: Samagotchi::Session::STATUS_RUNNING)

      expect { Samagotchi::SessionManager.archive_session(busy.id, state_dir: tmpdir) }
        .to raise_error(Samagotchi::SessionManager::ArchiveRefused, /a turn is running/)
      expect(archived?(busy)).to be(false)
    end

    it "refuses while a delegate of it runs a turn, naming the delegate, and archives none" do
      parent = make
      child = make(parent: parent, owner: "worker", status: Samagotchi::Session::STATUS_RUNNING)

      expect { Samagotchi::SessionManager.archive_session(parent.id, state_dir: tmpdir) }
        .to raise_error(Samagotchi::SessionManager::ArchiveRefused, /delegate #{child.id[0, 8]} is running a turn/)
      expect([archived?(parent), archived?(child)]).to eq([false, false])
    end

    it "refuses a session a chi REPL owns, as delete does" do
      open_one = make(owner: "tui")

      expect { Samagotchi::SessionManager.archive_session(open_one.id, state_dir: tmpdir) }
        .to raise_error(Samagotchi::SessionManager::OwnedByTUI) { |e| expect(e.session_id).to eq(open_one.id) }
      expect(archived?(open_one)).to be(false)
    end

    it "names the delegate a chi REPL owns in the error's session_id" do
      parent = make
      child = make(parent: parent, owner: "tui")

      expect { Samagotchi::SessionManager.archive_session(parent.id, state_dir: tmpdir) }
        .to raise_error(Samagotchi::SessionManager::OwnedByTUI) { |e| expect(e.session_id).to eq(child.id) }
    end

    it "refuses a scratch session: it is deleted when you leave" do
      scratch = make(scratch: true)

      expect { Samagotchi::SessionManager.archive_session(scratch.id, state_dir: tmpdir) }
        .to raise_error(Samagotchi::SessionManager::ArchiveRefused,
                        "a scratch session is deleted when you leave; nothing to archive")
      expect(archived?(scratch)).to be(false)
    end

    it "raises ArgumentError for an unknown id" do
      expect { Samagotchi::SessionManager.archive_session("nope", state_dir: tmpdir) }.to raise_error(ArgumentError, /no session nope/)
      expect { Samagotchi::SessionManager.unarchive_session("../x", state_dir: tmpdir) }.to raise_error(ArgumentError)
    end
  end
end
