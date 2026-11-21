# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_continue"
require "samagotchi/session_chain/delete"
require "samagotchi/schedules"
require "samagotchi/child_reports"
require "samagotchi/tools/task_runtime"

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

  describe "plan digests" do
    let(:delegate_plan) { Samagotchi::SessionManager::DelegateRule::Plan }

    it "does not depend on the order of ids or per-link delegate plans" do
      first = described_class::LinkPlan.new(
        id: "link", previous: "previous", revive: %w[b a], moved: %w[d c],
        delegates: delegate_plan.new(delete: %w[f e], leave: %w[h g]), notes: 0
      )
      reordered = first.with(
        revive: %w[a b], moved: %w[c d],
        delegates: delegate_plan.new(delete: %w[e f], leave: %w[g h])
      )
      chain = described_class::ChainPlan.new(
        id: "link", links: %w[b a],
        delegates: {
          "b" => delegate_plan.new(delete: %w[d c], leave: %w[f e]),
          "a" => delegate_plan.new(delete: %w[j i], leave: %w[l k])
        }, cut_off: false
      )
      reordered_chain = chain.with(
        links: %w[a b],
        delegates: {
          "a" => delegate_plan.new(delete: %w[i j], leave: %w[k l]),
          "b" => delegate_plan.new(delete: %w[c d], leave: %w[e f])
        }
      )

      expect(described_class.digest(first)).to eq(described_class.digest(reordered))
      expect(described_class.digest(chain)).to eq(described_class.digest(reordered_chain))
    end

    it "deletes a link and a chain when their expected digests match" do
      previous = make
      link = continue(previous.id)
      link_plan = described_class.link_plan(link.id, state_dir: tmpdir, links: Samagotchi::SessionChain::Links.new(state_dir: tmpdir))

      expect(delete(link.id, expect: described_class.digest(link_plan))[:deleted]).to include(link.id)

      root = make
      chain = continue(root.id)
      chain_plan = described_class.chain_plan(chain.id, state_dir: tmpdir, links: Samagotchi::SessionChain::Links.new(state_dir: tmpdir))

      expect(manager.delete_chain(chain.id, state_dir: tmpdir, stop: true, expect: described_class.digest(chain_plan))[:deleted])
        .to contain_exactly(root.id, chain.id)
    end

    it "refuses before changes when a delegate stops running after preview" do
      previous = make
      link = continue(previous.id)
      delegate = make(parent: link)
      own(delegate.id)
      plan = described_class.link_plan(link.id, state_dir: tmpdir, links: Samagotchi::SessionChain::Links.new(state_dir: tmpdir))
      expect(plan.delegates.leave).to include(delegate.id)
      digest = described_class.digest(plan)
      locks.pop.release
      before = Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id).sort

      expect { delete(link.id, expect: digest) }.to raise_error(manager::DeleteRefused) { |error|
        expect([error.reason, error.message]).to eq([
          :plan_changed, "what this delete would do changed since it was shown; review the new plan and try again"
        ])
      }
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id).sort).to eq(before)
      expect(parent_of(delegate.id)).to eq(link.id)
      expect(archived?(previous.id)).to be(true)
    end
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

  # A session in no chain is a link with nothing to undo: its delegates
  # follow SessionManager::DELEGATES as a link's do.
  describe "a session in no chain" do
    def all_ids = Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id).sort
    def file_of(id) = Samagotchi::Session.session_file(id, state_dir: tmpdir)

    it "takes its stopped and archived delegates; a running one stays whole with its stopped child" do
      plain = make
      stopped = make(parent: plain)
      archived = make(parent: plain).tap { |c| Samagotchi::ArchiveStore.archive(c.id, state_dir: tmpdir) }
      running = make(parent: plain)
      grandchild = make(parent: running)
      own(running.id)
      untouched = [running.id, grandchild.id].to_h { |id| [id, File.read(file_of(id))] }

      result = delete(plain.id)

      expect(result.keys).to include(:id, :removed, :stopped, :unarchived, :moved_back, :deleted, :left_running)
      expect(result).to include(id: plain.id, unarchived: [], moved_back: [], stopped: false)
      expect(result[:deleted]).to contain_exactly(stopped.id, archived.id, plain.id)
      expect(result[:deleted].last).to eq(plain.id)
      expect(result[:left_running]).to eq([running.id, grandchild.id])
      expect([exists?(plain.id), exists?(stopped.id), exists?(archived.id)]).to eq([false, false, false])
      expect(untouched.to_h { |id, _| [id, File.read(file_of(id))] }).to eq(untouched)
      expect(parent_of(grandchild.id)).to eq(running.id)
    end

    it "takes a stopped delegate and leaves its running child without a parent" do
      plain = make
      stopped = make(parent: plain)
      child = make(parent: stopped)
      own(child.id)

      result = delete(plain.id)

      expect(result).to include(deleted: [stopped.id, plain.id], left_running: [child.id])
      expect([exists?(stopped.id), exists?(child.id)]).to eq([false, true])
    end

    it "is refused, nothing gone, when a delegate that would go is a schedule's target" do
      plain = make
      d = make(parent: plain)
      entry = Samagotchi::Schedules.new(state_dir: tmpdir).add(target: d.id, prompt: "Audit", recurrence: { "every" => "1h" })
      before = all_ids

      expect { delete(plain.id) }.to raise_error(manager::DeleteRefused) { |e|
        expect([e.reason, e.session_id, e.schedule_id]).to eq([:scheduled, d.id, entry.id])
      }
      expect(all_ids).to eq(before)
    end

    it "is refused when it is a schedule's target, in a one-turn run, or has a worker it isn't asked to stop" do
      scheduled = make
      Samagotchi::Schedules.new(state_dir: tmpdir).add(target: scheduled.id, prompt: "Audit", recurrence: { "every" => "1h" })
      one_turn = make
      locks << Samagotchi::OwnerLock.acquire(dir_of(one_turn.id), kind: "tui")
      busy = make
      own(busy.id)

      expect { delete(scheduled.id) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:scheduled) }
      expect { delete(one_turn.id) }.to raise_error(manager::OwnedByTUI)
      expect { delete(busy.id, stop: false) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect([scheduled, one_turn, busy].map { |s| exists?(s.id) }).to eq([true, true, true])
    end

    it "deletes a folder whose session file is gone, with its stopped delegate" do
      plain = make
      d = make(parent: plain)
      FileUtils.mkdir_p(dir_of(plain.id))
      FileUtils.rm_f(file_of(plain.id))

      result = delete(plain.id)

      expect(result[:deleted]).to eq([d.id, plain.id])
      expect([exists?(plain.id), exists?(d.id)]).to eq([false, false])
    end

    it "purges the logs of a delegate that went when the session itself is refused after it" do
      plain = make
      d = make(parent: plain)
      allow(manager).to receive(:remove_files).and_wrap_original do |original, sid, *args, **kw|
        raise manager::DeleteRefused.new(sid, :changed) if sid == plain.id

        original.call(sid, *args, **kw)
      end
      allow(manager).to receive(:purge_removal_stores).and_call_original

      expect { delete(plain.id) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:changed) }
      expect([exists?(d.id), exists?(plain.id)]).to eq([false, true])
      expect(manager).to have_received(:purge_removal_stores).with([d.id], state_dir: tmpdir)
    end

    it "checks the caller's expect as for a link: the shown plan deletes, a changed one is refused" do
      plain = make
      d = make(parent: plain)
      links = Samagotchi::SessionChain::Links.new(state_dir: tmpdir)
      shown = described_class.digest(described_class.link_plan(plain.id, state_dir: tmpdir, links: links))
      make(parent: plain)

      expect { delete(plain.id, expect: shown) }.to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:plan_changed) }
      expect(all_ids).to include(plain.id, d.id)

      links = Samagotchi::SessionChain::Links.new(state_dir: tmpdir)
      now = described_class.digest(described_class.link_plan(plain.id, state_dir: tmpdir, links: links))
      expect(delete(plain.id, expect: now)[:deleted]).to include(d.id, plain.id)
    end
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

  # The background tasks the deleted links and delegates started
  # (SessionManager::RunningTasks).
  describe "running background tasks" do
    let(:runtime) { Samagotchi::Tools::TaskRuntime }
    let(:policies) { manager::RunningTasks::Policy }
    let(:folder) { File.realpath(Dir.mktmpdir("chain-delete-tasks")) }
    let(:tasks) { [] }

    # The tasks run in the sessions' folder, as a worker's would.
    around { |example| Dir.chdir(folder) { example.run } }

    after do
      tasks.each { |record| runtime.stop_task(record.id, by: "model") }
      runtime.quiesce!(timeout: 5)
    end

    def all_ids = Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id).sort

    # A real task (this group's Process.spawn stands in only for a worker's).
    def start_task(session, command = "sleep 30")
      allow(Process).to receive(:spawn).and_call_original
      record, error = runtime.create_task(command)
      allow(Process).to receive(:spawn).and_return(12_345)
      raise error if error

      session = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      session.messages << { role: "tool_response", content: "[task_create]\ntask_id: #{record.id}" }
      session.save(state_dir: tmpdir)
      tasks << record
      record
    end

    def status_of(record) = runtime.load_record(record.id).status

    it "refuses a link for a task its D7 delegate started, before anything goes" do
      a = make
      b = continue(a.id)
      d = make(parent: b)
      start_task(d, "rspec spec/slow_spec.rb")
      before = all_ids

      expect { delete(b.id, running_tasks: policies::REFUSE) }
        .to raise_error(manager::DeleteRefused) { |e|
          expect([e.reason, e.session_id]).to eq([:tasks_running, b.id])
          expect(e.message).to eq("its delegate #{d.id[0, 8]}'s background tasks are still running: rspec spec/slow_spec.rb")
        }
      expect(all_ids).to eq(before)
    end

    # The last check lists the whole batch once under its locks: a task that
    # starts on the link after check_link! refuses before its delegate goes.
    it "keeps the link and its delegate when a task starts on the link after the up-front check" do
      a = make
      b = continue(a.id)
      d = make(parent: b)
      allow(described_class).to receive(:check_link!).and_wrap_original do |original, *args, **kw|
        original.call(*args, **kw).tap { start_task(b, "sleep 30.25") }
      end

      expect { delete(b.id, running_tasks: policies::REFUSE) }
        .to raise_error(manager::DeleteRefused) { |e| expect([e.reason, e.session_id]).to eq([:tasks_running, b.id]) }
      expect([exists?(b.id), exists?(d.id)]).to eq([true, true])
      expect(archived?(a.id)).to be(true)
    end

    it "keeps a chain whole when a task starts on its newest link after the up-front check" do
      a = make
      b = continue(a.id)
      d = make(parent: b)
      allow(described_class).to receive(:check_chain!).and_wrap_original do |original, *args, **kw|
        original.call(*args, **kw).tap { start_task(b, "sleep 30.26") }
      end

      expect { manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies::REFUSE) }
        .to raise_error(manager::DeleteRefused) { |e| expect(e.reason).to eq(:tasks_running) }
      expect([exists?(a.id), exists?(b.id), exists?(d.id)]).to eq([true, true, true])
    end

    it "refuses a chain delete up front for a task an earlier link started, naming that link" do
      a = make
      b = continue(a.id)
      start_task(a, "npm run dev")
      before = all_ids

      expect { manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies::REFUSE) }
        .to raise_error(manager::DeleteRefused, "link #{a.id[0, 8]}'s background tasks are still running: npm run dev")
      expect(all_ids).to eq(before)
    end

    it "stops a chain's tasks link by link, newest first, each under its link's lock" do
      a = make
      b = continue(a.id)
      in_a = start_task(a, "sleep 30.21")
      in_b = start_task(b, "sleep 30.22")
      order = []
      allow(manager::RunningTasks).to receive(:stop!).and_wrap_original do |original, listing, **kw|
        order.concat(listing.running.map(&:id))
        original.call(listing, **kw)
      end

      result = manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies.stop(by: "user"))

      expect(order).to eq([in_b.id, in_a.id])
      expect(result[:tasks_stopped].map(&:id)).to contain_exactly(in_a.id, in_b.id)
      expect([status_of(in_a), status_of(in_b)]).to eq(%w[stopped stopped])
      expect([exists?(a.id), exists?(b.id)]).to eq([false, false])
    end

    # The delete sheet's tap: a stop given the task ids the sheet named.
    describe "a stop given the named tasks (only:)" do
      it "stops the named tasks of a session in no chain and its delegate, then deletes both" do
        plain = make
        d = make(parent: plain)
        in_plain = start_task(plain, "sleep 30.31")
        in_d = start_task(d, "sleep 30.32")

        result = delete(plain.id, running_tasks: policies.stop(by: "user", only: [in_plain.id, in_d.id]))

        expect(result[:deleted]).to eq([d.id, plain.id])
        expect(result[:tasks_stopped].map(&:id)).to contain_exactly(in_plain.id, in_d.id)
        expect([status_of(in_plain), status_of(in_d)]).to eq(%w[stopped stopped])
      end

      it "refuses up front on a task it wasn't given: no worker stopped, nothing gone or stopped" do
        plain = make
        d = make(parent: plain)
        named = start_task(plain, "sleep 30.33")
        unnamed = start_task(d, "sleep 30.34")
        allow(manager).to receive(:release_for_delete!).and_call_original
        before = all_ids

        expect { delete(plain.id, running_tasks: policies.stop(by: "user", only: [named.id])) }
          .to raise_error(manager::DeleteRefused) { |e|
            expect(e).to have_attributes(reason: :tasks_running, session_id: plain.id, worker_stopped: false)
            expect(e.tasks.running.map(&:id)).to contain_exactly(named.id, unnamed.id)
          }
        expect(manager).not_to have_received(:release_for_delete!)
        expect(all_ids).to eq(before)
        expect([status_of(named), status_of(unnamed)]).to eq(%w[running running])
      end

      it "refuses under the lock on one that started after the check, nothing gone, the worker's stop said" do
        plain = make
        d = make(parent: plain)
        named = start_task(plain, "sleep 30.37")
        allow(manager).to receive(:release_for_delete!).and_return(true)
        allow(described_class).to receive(:check_link!).and_wrap_original do |original, *args, **kw|
          original.call(*args, **kw).tap { start_task(d, "sleep 30.38") }
        end
        before = all_ids

        expect { delete(plain.id, running_tasks: policies.stop(by: "user", only: [named.id])) }
          .to raise_error(manager::DeleteRefused) { |e|
            expect(e).to have_attributes(reason: :tasks_running, session_id: plain.id, worker_stopped: true,
                                         stopped_worker: plain.id)
          }
        expect(all_ids).to eq(before)
        expect(status_of(named)).to eq("running")
      end

      # The batch's check under the locks is the last word: a record read
      # again per id (one unreadable a moment before) refuses nothing there,
      # so no delegate goes before a refusal.
      it "doesn't refuse an id after its delegate went once the batch was checked" do
        plain = make
        d = make(parent: plain)
        late = manager::RunningTasks::RunningTask.new(session_id: plain.id, id: "20261121000000-0badf00d", command: "x",
                                                      root: folder)
        allow(manager::RunningTasks).to receive(:of).and_wrap_original do |original, ids, **kw|
          ids == [plain.id] ? manager::RunningTasks::Listing.new(running: [late]) : original.call(ids, **kw)
        end

        result = delete(plain.id, running_tasks: policies.stop(by: "user", only: []))

        expect([exists?(d.id), exists?(plain.id)]).to eq([false, false])
        expect(result[:deleted]).to eq([d.id, plain.id])
      end

      it "deletes a session whose only task is unverified, never signalling it" do
        plain = make
        allow(Process).to receive(:spawn).and_call_original
        pid = Process.spawn("sleep", "31.93", pgroup: true)
        allow(Process).to receive(:spawn).and_return(12_345)
        record = Samagotchi::Tools::TaskRecord.from_file(
          "id" => runtime.generate_task_id, "command" => "sleep 40", "status" => "running", "pid" => pid,
          "created_at" => "2026-10-01T00:00:00Z", "exit_code_path" => File.join(folder, "no-exit-code")
        )
        runtime.write_record(record)
        session = Samagotchi::Session.load(plain.id, state_dir: tmpdir)
        session.messages << { role: "tool_response", content: "[task_create]\ntask_id: #{record.id}" }
        session.save(state_dir: tmpdir)

        result = delete(plain.id, running_tasks: policies.stop(by: "user", only: []))

        expect(exists?(plain.id)).to be(false)
        expect(result[:tasks_not_stopped].map(&:id)).to eq([record.id])
        expect(Process.wait2(pid, Process::WNOHANG)).to be_nil
      ensure
        if pid
          Process.kill("KILL", -pid)
          Process.wait(pid)
        end
      end

      # The review's probe: the sheet named the newest link's task; one the
      # sheet didn't name runs in the older link. Refused up front, not part-way.
      it "refuses a chain whole, up front, on a task it wasn't given in an older link" do
        a = make
        b = continue(a.id)
        named = start_task(b, "sleep 30.35")
        unnamed = start_task(a, "sleep 30.36")
        allow(manager).to receive(:release_for_delete!).and_call_original

        expect do
          manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies.stop(by: "user", only: [named.id]))
        end.to raise_error(manager::DeleteRefused) { |e|
          expect(e).to have_attributes(reason: :tasks_running, worker_stopped: false)
          expect(e.tasks.running.map(&:id)).to contain_exactly(named.id, unnamed.id)
        }
        expect(manager).not_to have_received(:release_for_delete!)
        expect([exists?(a.id), exists?(b.id)]).to eq([true, true])
        expect([status_of(named), status_of(unnamed)]).to eq(%w[running running])
      end

      it "keeps a chain whole on a task started on its newest link after the check, saying whose worker was stopped" do
        a = make
        b = continue(a.id)
        named = start_task(a, "sleep 30.39")
        allow(manager).to receive(:release_for_delete!).and_return(true)
        allow(described_class).to receive(:check_chain!).and_wrap_original do |original, *args, **kw|
          original.call(*args, **kw).tap { start_task(b, "sleep 30.40") }
        end

        expect do
          manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies.stop(by: "user", only: [named.id]))
        end.to raise_error(manager::DeleteRefused) { |e|
          expect(e).to have_attributes(reason: :tasks_running, session_id: b.id, stopped_worker: b.id)
        }
        expect([exists?(a.id), exists?(b.id)]).to eq([true, true])
        expect(status_of(named)).to eq("running")
      end
    end

    it "keeps a link refused part-way whole with its task running; the later link's task is stopped" do
      a = make
      b = continue(a.id)
      in_a = start_task(a, "sleep 30.23")
      in_b = start_task(b, "sleep 30.24")
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_wrap_original do |original, dir, **kw|
        next nil if dir == dir_of(a.id) && kw[:kind] == Samagotchi::OwnerLock::DELETING

        original.call(dir, **kw)
      end

      result = manager.delete_chain(b.id, state_dir: tmpdir, stop: true, running_tasks: policies.stop(by: "user"))

      expect(result).to include(deleted: [b.id], left: [a.id])
      expect([status_of(in_b), status_of(in_a)]).to eq(%w[stopped running])
      expect(exists?(a.id)).to be(true)
    end
  end
end
