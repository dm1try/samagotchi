# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/note_delivery"
require "samagotchi/owner_lock"
require "samagotchi/archive_store"

RSpec.describe Samagotchi::NoteDelivery do
  let(:tmpdir) { Dir.mktmpdir("note-delivery") }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, continues: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                    continues: continues).tap do |s|
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: owner) if owner
    end
  end

  def notes_of(session)
    dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionInbox::NOTES_DIR)
    Dir.glob(File.join(dir, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  def deliver(session, text = "deploy frozen", **opts)
    described_class.deliver(session.id, text: text, source: "slack", state_dir: tmpdir, **opts)
  end

  it "queues the note for a session a worker runs" do
    live = make(owner: "worker")

    result = deliver(live, from_session: "abc", from_cwd: "/w")

    expect(result).to have_attributes(id: live.id, status: :queued, queued: 0, delivered?: true)
    expect(notes_of(live)).to contain_exactly(include("text" => "deploy frozen", "source" => "slack",
                                                      "from_session" => "abc", "from_cwd" => "/w"))
  end

  it "leaves the note for a session with no worker, counting the queue" do
    idle = make
    deliver(idle)

    expect(deliver(idle, "two")).to have_attributes(status: :waits, queued: 2, delivered?: true)
  end

  it "refuses a session a one-turn chi run owns, writing nothing" do
    repl = make(owner: "tui")

    expect(deliver(repl)).to have_attributes(status: :refused, delivered?: false)
    expect(notes_of(repl)).to eq([])
  end

  it "refuses a chi scratch session, live worker or not, writing nothing" do
    scratch = make(owner: "worker")
    scratch.scratch = true
    scratch.save(state_dir: tmpdir)

    result = deliver(scratch)
    expect(result).to have_attributes(status: :refused, delivered?: false, scratch: true)
    expect(result.refusal).to eq(Samagotchi::Session::SCRATCH_REFUSED)
    expect(notes_of(scratch)).to eq([])
  end

  describe "a session that was continued" do
    let(:old) { make.tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) } }

    it "follows the chain to its newest link, which holds the note for its next absorb" do
      head = make(continues: make(continues: old.id).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: tmpdir) }.id)

      result = deliver(old)

      expect(result).to have_attributes(id: head.id, asked: old.id, status: :waits, queued: 1, continued?: true)
      expect(notes_of(old)).to eq([])
      expect(notes_of(head)).to contain_exactly(include("text" => "deploy frozen", "source" => "slack"))
      expect(Samagotchi::SessionInbox.find_new_note_files(
        Samagotchi::Session.session_dir(head.id, state_dir: tmpdir)
      ).size).to eq(1)
    end

    it "is queued for the newest link's worker" do
      head = make(continues: old.id, owner: "worker")

      expect(deliver(old)).to have_attributes(id: head.id, status: :queued, queued: 0)
    end

    it "keeps the note in an archived link nobody continues: it waits there" do
      expect(deliver(old)).to have_attributes(id: old.id, asked: old.id, status: :waits, continued?: false)
      expect(notes_of(old).size).to eq(1)
    end

    it "keeps a pinned note (an objectives list) in the link named" do
      head = make(continues: old.id)

      expect(deliver(old, pin: true)).to have_attributes(id: old.id, asked: old.id)
      expect([notes_of(old).size, notes_of(head)]).to eq([1, []])
    end
  end

  it "says the session is gone, writing nothing" do
    expect do
      described_class.deliver("00000000-0000-0000-0000-000000000000", text: "x", source: "cli", state_dir: tmpdir)
    end.to raise_error(Samagotchi::Session::NotFound)
  end

  it "raises for an empty note" do
    expect { deliver(make, "  ") }.to raise_error(Samagotchi::SessionInbox::NoteRejected)
  end
end
