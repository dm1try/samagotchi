# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/broadcast/recipients"
require "samagotchi/archive_store"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::Broadcast::Recipients do
  let(:tmpdir) { Dir.mktmpdir("broadcast-recipients") }
  let(:locks) { [] }
  # Every save is "now" on the wall clock; the broadcast runs an hour later.
  let(:now) { Time.now + 3600 }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  # ended: hours before +now+ the last turn ended (nil: no turn recorded)
  def make(owner: nil, ended: nil, test_run: false, **attrs)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                    test_run: test_run, **attrs).tap do |s|
      s.last_prompt = "hi"
      s.last_turn = { "outcome" => "completed", "ended_at" => (now - (ended * 3600)).iso8601 } if ended
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: owner) if owner
    end
  end

  def ids(include_tests: false) = described_class.list(state_dir: tmpdir, active_hours: 8, include_tests: include_tests, now: now).map(&:id)

  it "takes sessions a worker or a chi REPL runs, and ones whose last turn ended within active_hours" do
    worker = make(owner: "worker", ended: 30)
    repl = make(owner: "tui", ended: 30)
    recent = make(ended: 2)
    stale = make(ended: 9)

    expect(ids).to contain_exactly(worker.id, repl.id, recent.id)
    expect(ids).not_to include(stale.id)
    rows = described_class.list(state_dir: tmpdir, active_hours: 8, include_tests: false, now: now).to_h { |r| [r.id, r] }
    expect(rows[repl.id]).to have_attributes(repl?: true, live: false, owner: "tui")
    expect(rows[worker.id]).to have_attributes(repl?: false, live: true, short_id: worker.id[0, 8])
  end

  it "goes by the last turn's end, not updated_at, which a note or a resume moves; updated_at only with no turn" do
    old_turn_saved_now = make(ended: 9)
    no_turn_recent = make
    no_turn_old = make
    file = Samagotchi::Session.session_file(no_turn_old.id, state_dir: tmpdir)
    File.write(file, JSON.generate(JSON.parse(File.read(file)).merge("updated_at" => (now - (10 * 3600)).iso8601)))

    expect(ids).to eq([no_turn_recent.id])
    expect(ids).not_to include(old_turn_saved_now.id)
  end

  it "leaves out delegate children, scratch and archived sessions, but takes forks" do
    parent = make(ended: 1)
    fork = make(ended: 1, parent_id: parent.id)
    make(ended: 1, parent_id: parent.id, delegate: true)
    make(owner: "worker", parent_id: parent.id, delegate: true)
    make(ended: 1, scratch: true)
    archived = make(ended: 1)
    Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)

    expect(ids).to contain_exactly(parent.id, fork.id)
  end

  it "takes test runs only when asked" do
    test = make(ended: 1, test_run: true)

    expect(ids).to eq([])
    expect(ids(include_tests: true)).to eq([test.id])
  end
end
