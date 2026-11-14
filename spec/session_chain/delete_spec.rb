# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_continue"
require "samagotchi/session_chain/delete"
require "samagotchi/schedules"
require "samagotchi/child_reports"

# A user's delete of a chain link (D2/D5/D7) and of the whole chain (D4).
RSpec.describe Samagotchi::SessionChain::Delete do
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

  describe "deleting the chain's newest link" do
    it "undoes the continue: the previous link back, not started, with what it archived, its moved delegates and notes" do
      a = make
      moved = unreported(a)
      finished = make(parent: a)
      own_archived = make(parent: a).tap { |c| Samagotchi::ArchiveStore.archive(c.id, state_dir: tmpdir) }
      b = continue(a.id)
      expect(parent_of(moved.id)).to eq(b.id)
      Samagotchi::SessionInbox.write_note(b.id, text: "for the chain", source: "someone", state_dir: tmpdir)
      spawns = 0
      allow(Process).to receive(:spawn) { spawns += 1 }

      result = delete(b.id)

      expect(exists?(b.id)).to be(false)
      expect(result[:moved_back]).to eq([moved.id])
      expect(result[:unarchived]).to contain_exactly(a.id, finished.id)
      expect([archived?(a.id), archived?(finished.id), archived?(own_archived.id)]).to eq([false, false, true])
      expect(parent_of(moved.id)).to eq(a.id)
      expect(notes(moved.id).last).to include("was deleted")
      expect(notes(a.id)).to include("for the chain")
      expect(spawns).to eq(0)
      expect(Samagotchi::SessionChain::Links.new(state_dir: tmpdir).first_live(a.id)).to eq(a.id)
    end

    it "brings back the previous link alone for a link an older chi made (no continued_from.json)" do
      a = make
      finished = make(parent: a)
      b = continue(a.id)
      FileUtils.rm_f(Samagotchi::ContinuedFrom.path(b.id, state_dir: tmpdir))

      expect(delete(b.id)[:unarchived]).to eq([a.id])
      expect([archived?(a.id), archived?(finished.id)]).to eq([false, true])
    end

    it "gives each step's moved delegates back by its own record in a nested undo" do
      a = make
      first = unreported(a)
      b = continue(a.id)
      second = unreported(b)
      c = continue(b.id)
      expect([parent_of(first.id), parent_of(second.id)]).to eq([c.id, c.id])

      expect(delete(c.id)[:moved_back]).to contain_exactly(first.id, second.id)
      expect(delete(b.id)[:moved_back]).to eq([first.id])

      # second is B's own delegate: D7 deletes it with B (finished).
      expect(parent_of(first.id)).to eq(a.id)
      expect(exists?(second.id)).to be(false)
      expect(archived?(a.id)).to be(false)
    end

    it "is refused before anything moves back when a worker took the link after the stop, and a retry finishes" do
      a = make
      moved = unreported(a)
      b = continue(a.id)
      taken = true
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_wrap_original do |original, dir, **kw|
        next nil if taken && dir == dir_of(b.id) && kw[:kind] == Samagotchi::OwnerLock::DELETING

        original.call(dir, **kw)
      end

      expect { delete(b.id) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect([exists?(b.id), parent_of(moved.id), archived?(a.id)]).to eq([true, b.id, true])

      taken = false
      result = delete(b.id)
      expect(exists?(b.id)).to be(false)
      expect(result).to include(moved_back: [moved.id], unarchived: [a.id])
    end

    it "is refused while a continue of it is under way, and while the previous link is being continued" do
      a = make
      b = continue(a.id)
      [b.id, a.id].each do |held|
        File.open(File.join(dir_of(held), Samagotchi::ContinueIntent::LOCK), File::RDWR | File::CREAT) do |lock|
          lock.flock(File::LOCK_EX)
          expect { delete(b.id) }.to raise_error(manager::DeleteRefused) { |e|
            expect([e.reason, e.session_id]).to eq([:continuing, held])
          }
        end
      end
      expect(exists?(b.id)).to be(true)
    end

    it "is refused, nothing changed, when a moved delegate can't go back" do
      a = make
      moved = unreported(a)
      b = continue(a.id)
      allow(Samagotchi::ChildMove).to receive(:unmovable).and_return(nil)
      allow(Samagotchi::ChildMove).to receive(:unmovable).with(moved.id, state_dir: tmpdir).and_return("older chi worker 0.1; restart it")

      expect { delete(b.id) }.to raise_error(manager::DeleteRefused) { |e|
        expect([e.reason, e.ids]).to eq([:delegate_unmovable, [moved.id]])
        expect(e.message).to include(moved.id[0, 8], "older chi worker")
      }
      expect([exists?(b.id), parent_of(moved.id), archived?(a.id)]).to eq([true, b.id, true])
    end
  end

  it "refuses a middle link that is a schedule's head, before anything is deleted" do
    a = make
    b = continue(a.id)
    continue(b.id)
    schedules = Samagotchi::Schedules.new(state_dir: tmpdir)
    entry = schedules.add(target: a.id, prompt: "Audit", recurrence: { "every" => "1h" })
    schedules.send(:write_under_lock) { |file| file.entries.map! { |e| e.id == entry.id ? e.with(head: b.id) : e } }

    expect { delete(b.id) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:scheduled) }
    expect(exists?(b.id)).to be(true)
  end

  it "leaves a session in no chain to the plain delete" do
    plain = make
    child = make(parent: plain)

    expect(delete(plain.id)).to include(id: plain.id, unarchived: [], moved_back: [], left_running: [])
    expect(exists?(child.id)).to be(true)
  end

  it "never revives without the keywords (the scratch cleanup, the discard, the rollback and the prune's delete)" do
    a = make
    b = continue(a.id)

    manager.delete_session(b.id, state_dir: tmpdir)

    expect(archived?(a.id)).to be(true)
  end

  describe "refusals leave every session in place" do
    def all_ids = Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id).sort

    it "refuses a link whose delegate is a schedule's target before anything goes, its finished grandchild too" do
      a = make
      m = continue(a.id)
      continue(m.id)
      d = make(parent: m)
      make(parent: d)
      entry = Samagotchi::Schedules.new(state_dir: tmpdir).add(target: d.id, prompt: "Audit", recurrence: { "every" => "1h" })
      before = all_ids

      expect { delete(m.id) }.to raise_error(manager::DeleteRefused) { |e|
        expect([e.reason, e.session_id, e.schedule_id]).to eq([:scheduled, d.id, entry.id])
      }
      expect(all_ids).to eq(before)
    end

    it "refuses, deleting none of its delegates, when a worker took the link after the stop" do
      a = make
      m = continue(a.id)
      continue(m.id)
      make(parent: m).tap { |d| make(parent: d) }
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_wrap_original do |original, dir, **kw|
        next nil if dir == dir_of(m.id) && kw[:kind] == Samagotchi::OwnerLock::DELETING

        original.call(dir, **kw)
      end
      before = all_ids

      expect { delete(m.id) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(all_ids).to eq(before)
    end

    it "refuses a chain delete before anything goes when a link's worker outlives the stop's wait" do
      a = make
      b = continue(a.id)
      make(parent: b)
      own(b.id)
      allow(manager).to receive(:stop_session).and_return(false)
      before = all_ids

      expect { manager.delete_chain(a.id, state_dir: tmpdir, stop: true, wait: 0) }
        .to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(all_ids).to eq(before)
    end

    it "refuses a chain delete before anything goes when a delegate that would go is a schedule's target" do
      a = make
      b = continue(a.id)
      d = make(parent: a)
      Samagotchi::Schedules.new(state_dir: tmpdir).add(target: d.id, prompt: "Audit", recurrence: { "every" => "1h" })
      before = all_ids

      expect { manager.delete_chain(b.id, state_dir: tmpdir, stop: true) }
        .to raise_error(manager::DeleteRefused) { |e| expect([e.reason, e.session_id]).to eq([:scheduled, d.id]) }
      expect(all_ids).to eq(before)
    end

    it "keeps a link refused part-way whole, with its delegates and the earlier links" do
      a = make
      a_child = make(parent: a)
      b = continue(a.id)
      b_child = make(parent: b)
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_wrap_original do |original, dir, **kw|
        next nil if dir == dir_of(a.id) && kw[:kind] == Samagotchi::OwnerLock::DELETING

        original.call(dir, **kw)
      end

      result = manager.delete_chain(b.id, state_dir: tmpdir, stop: true)

      expect(result).to include(deleted: [b_child.id, b.id], left: [a.id])
      expect(result[:refusal]).to include("worker is running")
      expect([exists?(a.id), exists?(a_child.id)]).to eq([true, true])
      expect(archived?(a.id)).to be(false)
    end
  end

  it "logs a fork the chain walk meets" do
    a = make
    b = continue(a.id)
    other = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder, continues: a.id)
                               .tap { |s| s.save(state_dir: tmpdir) }
    allow(Samagotchi::Log).to receive(:debug)

    expect(Samagotchi::SessionChain::Links.new(state_dir: tmpdir).chain(b.id)).to eq([a.id, b.id])
    expect(Samagotchi::Log).to have_received(:debug).with(:worker, "chain_fork", sid: a.id[0, 8], others: [other.id[0, 8]])
  end

  describe "DELEGATES" do
    it "leaves a running delegate with its whole subtree, deletes the rest deepest first" do
      link = make
      running = make(parent: link)
      own(running.id)
      stopped_under_running = make(parent: running)
      stopped = make(parent: link)
      grandchild = make(parent: stopped)

      plan = described_class::DELEGATES.plan(link.id, state_dir: tmpdir)

      expect(plan.leave).to contain_exactly(running.id, stopped_under_running.id)
      expect(plan.delete).to eq([grandchild.id, stopped.id])
    end
  end

  describe ".chain" do
    it "deletes every link and its stopped delegates; a running delegate keeps running, its file untouched" do
      a = make
      b = continue(a.id)
      middle_child = make(parent: b)
      c = continue(b.id)
      running = make(parent: c)
      own(running.id)
      before = File.read(Samagotchi::Session.session_file(running.id, state_dir: tmpdir))

      result = manager.delete_chain(b.id, state_dir: tmpdir, stop: true)

      expect(result[:deleted]).to include(a.id, b.id, c.id, middle_child.id)
      expect(result).to include(left: [], left_running: [running.id], cut_off: false)
      [a, b, c, middle_child].each { |s| expect(exists?(s.id)).to be(false) }
      expect(File.read(Samagotchi::Session.session_file(running.id, state_dir: tmpdir))).to eq(before)
      # Its next report has nowhere to go, and brings no parent folder back.
      left = Samagotchi::Session.load(running.id, state_dir: tmpdir)
      expect(Samagotchi::ChildRing.ring(left, why: "turn_end", state_dir: tmpdir, wake: ->(_) {})).to be_nil
      expect(Dir.exist?(dir_of(c.id))).to be(false)
    end

    it "is refused before anything goes when a schedule is on the chain" do
      a = make
      b = continue(a.id)
      Samagotchi::Schedules.new(state_dir: tmpdir).add(target: a.id, prompt: "Audit", recurrence: { "every" => "1h" })

      expect { manager.delete_chain(b.id, state_dir: tmpdir, stop: true) }
        .to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:chain_scheduled) }
      expect([exists?(a.id), exists?(b.id)]).to eq([true, true])
    end

    it "reaches only the part after a gap, and says a gap cut links off" do
      a = make
      b = continue(a.id)
      c = continue(b.id)
      manager.delete_session(b.id, state_dir: tmpdir, allow_scheduled: true)

      result = manager.delete_chain(c.id, state_dir: tmpdir, stop: true)

      expect(result).to include(deleted: [c.id], cut_off: true)
      expect(exists?(a.id)).to be(true)
    end
  end
end
