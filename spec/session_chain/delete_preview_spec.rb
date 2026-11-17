# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_continue"
require "samagotchi/session_chain/delete_preview"
require "samagotchi/schedules"

# What the web's delete sheet shows (GET …/delete_plan): the delete's own
# plans and refusals, read now.
RSpec.describe Samagotchi::SessionChain::Delete::Preview do
  let(:manager) { Samagotchi::SessionManager }
  let(:tmpdir) { Dir.mktmpdir("chain-delete") }
  let(:folder) { Dir.mktmpdir("chain-delete-folder") }
  let(:locks) { [] }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
    FileUtils.rm_rf(folder)
  end

  def make(parent: nil, status: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: folder,
                                    parent_id: parent&.id, delegate: !parent.nil?).tap do |s|
      s.first_preview = "p"
      s.messages = [{ role: "user", content: "p" }, { role: "assistant", content: "ok" }]
      s.status = status if status
      s.save(state_dir: tmpdir)
    end
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def archived?(id) = Samagotchi::ArchiveStore.archived?(dir_of(id))
  def exists?(id) = File.exist?(Samagotchi::Session.session_file(id, state_dir: tmpdir)) || Dir.exist?(dir_of(id))
  def own(id) = locks << Samagotchi::OwnerLock.acquire(dir_of(id), kind: "worker")
  def parent_of(id) = Samagotchi::Session.load(id, state_dir: tmpdir).parent_id
  def unreported(parent) = make(parent: parent).tap { |c| Samagotchi::SessionInbox.write_output(dir_of(c.id), "done") }

  # The next link, its worker as if it came and went (no starting marker).
  def continue(id)
    Samagotchi::SessionContinue.run(id, state_dir: tmpdir, recap_wait: 0).tap do |link|
      FileUtils.rm_f(File.join(dir_of(link.id), Samagotchi::StartingMarker::FILE))
    end
  end

  def delete(id, **) = manager.delete_session(id, state_dir: tmpdir, stop: true, revive_previous: true,
                                                  refuse_continuing: true, **)

  def notes(id)
    Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f)[:text] }
  end

  def preview(id) = described_class.call(id, state_dir: tmpdir)

  it "takes a nil state dir as the default one, as chi web passes it" do
    a = make
    b = continue(a.id)
    allow(Samagotchi::Session).to receive(:default_state_dir).and_return(tmpdir)

    expect(described_class.call(b.id, state_dir: nil)).to include(chained: true, position: 2)
  end

  it "says a session in no chain is not chained" do
    plain = make
    expect(preview(plain.id)).to eq(chained: false, session_id: plain.id)
  end

  it "counts what deleting the newest link of 3 gives back and deletes, and the delete then does exactly that" do
    first = make
    a = continue(first.id)
    moved = unreported(a)
    b = continue(a.id)
    stopped = make(parent: b)
    running = make(parent: b)
    own(running.id)
    Samagotchi::SessionInbox.write_note(b.id, text: "for the chain", source: "someone", state_dir: tmpdir)

    shown = preview(b.id)

    expect(shown).to include(chained: true, position: 3, size: 3, cut_off: false)
    expect(shown[:link]).to include(previous_id: a.id, moved: 1, notes: 1, unarchived: 1, deletes: 1, left_running: 1,
                                    earlier: 2, next_id: nil, later: 0, refusal: nil)
    expect(shown[:link][:digest]).to match(/\A[0-9a-f]{16}\z/)
    expect(shown[:chain]).to include(links: 3, deletes: 2, left_running: 1, refusal: nil)
    expect(shown[:chain][:digest]).to match(/\A[0-9a-f]{16}\z/)

    result = delete(b.id)
    expect(result[:moved_back].size).to eq(shown[:link][:moved])
    expect(result[:unarchived].size).to eq(shown[:link][:unarchived])
    expect(result[:deleted]).to eq([stopped.id, b.id])
    expect(result[:left_running]).to eq([running.id])
    expect(parent_of(moved.id)).to eq(a.id)
  end

  it "counts each moved delegate with its subtree: the sessions that actually come back" do
    a = make
    moved = unreported(a)
    grandchild = make(parent: moved)
    b = continue(a.id)

    count = preview(b.id)[:link][:moved]
    delete(b.id)

    back = manager.descendant_ids(a.id, tmpdir) & [moved.id, grandchild.id]
    expect(count).to eq(2)
    expect(back.size).to eq(count)
  end

  it "shows a middle link's split: earlier links, the next link, nothing undone" do
    a = make
    b = continue(a.id)
    c = continue(b.id)

    expect(preview(b.id)).to include(position: 2, size: 3)
    expect(preview(b.id)[:link]).to include(previous_id: nil, moved: 0, earlier: 1, next_id: c.id, later: 1)
  end

  it "refuses both choices up front when a schedule's head is the link, naming the schedule" do
    a = make
    b = continue(a.id)
    entry = Samagotchi::Schedules.new(state_dir: tmpdir).add(target: b.id, prompt: "Audit", recurrence: { "every" => "1h" })

    shown = preview(b.id)

    expect(shown[:link][:refusal]).to include(reason: "scheduled", schedule_id: entry.id)
    expect(shown[:chain][:refusal]).to include(reason: "chain_scheduled", schedule_id: entry.id)
    expect(shown[:chain][:refusal][:message]).to include("chi schedule cancel #{entry.id}")
  end

  it "refuses both choices up front when a delegate that would go is a schedule's target, naming it" do
    a = make
    b = continue(a.id)
    d = make(parent: b)
    entry = Samagotchi::Schedules.new(state_dir: tmpdir).add(target: d.id, prompt: "Audit", recurrence: { "every" => "1h" })

    shown = preview(b.id)

    expect(shown[:link][:refusal]).to include(reason: "scheduled", schedule_id: entry.id)
    expect(shown[:chain][:refusal]).to include(reason: "scheduled", schedule_id: entry.id)
    expect(shown[:link][:refusal][:message]).to eq("its delegate #{d.id[0, 8]} is the target of an enabled schedule; " \
                                                   "cancel it with chi schedule cancel #{entry.id}")
  end

  it "names a moved delegate that can't go back, stoppable unless a one-turn run has it" do
    a = make
    moved = unreported(a)
    b = continue(a.id)
    allow(Samagotchi::ChildMove).to receive(:unmovable).and_return(nil)
    allow(Samagotchi::ChildMove).to receive(:unmovable).with(moved.id, state_dir: tmpdir).and_return("older chi worker; restart it")

    expect(preview(b.id)[:link][:refusal]).to include(reason: "delegate_unmovable", ids: [moved.id], stoppable: true)

    locks << Samagotchi::OwnerLock.acquire(dir_of(moved.id), kind: "tui")
    expect(preview(b.id)[:link][:refusal]).to include(reason: "delegate_unmovable", stoppable: false)
  end

  it "says a continue of the link under way refuses both" do
    a = make
    b = continue(a.id)
    File.open(File.join(dir_of(b.id), Samagotchi::ContinueIntent::LOCK), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      shown = preview(b.id)
      expect([shown[:link][:refusal][:reason], shown[:chain][:refusal][:reason]]).to eq(%w[continuing continuing])
    end
  end

  it "says a gap before the link cut earlier links off" do
    a = make
    b = continue(a.id)
    c = continue(b.id)
    manager.delete_session(b.id, state_dir: tmpdir, allow_scheduled: true)

    d = continue(c.id)

    expect(preview(d.id)).to include(cut_off: true, position: 2, size: 2)
    # A link alone past the gap is no chain: today's confirm.
    expect(preview(a.id)).to eq(chained: false, session_id: a.id)
  end
end
