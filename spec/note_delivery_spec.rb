# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/note_delivery"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::NoteDelivery do
  let(:tmpdir) { Dir.mktmpdir("note-delivery") }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
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

  it "refuses a session a chi REPL owns, writing nothing" do
    repl = make(owner: "tui")

    expect(deliver(repl)).to have_attributes(status: :refused, delivered?: false)
    expect(notes_of(repl)).to eq([])
  end

  it "raises for an empty note" do
    expect { deliver(make, "  ") }.to raise_error(Samagotchi::SessionInbox::NoteRejected)
  end
end
