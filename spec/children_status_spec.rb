# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/children_status"
require "samagotchi/owner_lock"
require "samagotchi/session_inbox"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::ChildrenStatus do
  let(:tmpdir) { Dir.mktmpdir("children-status") }
  let(:locks) { [] }
  let(:parent) { make(prompt: "the plan") }
  let(:old) { (Time.now - 600).iso8601(3) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(prompt: "hello", parent_id: nil, delegate: false, status: nil, last_turn: nil, cwd: "/work/app",
           pending: nil, updated_at: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd, parent_id: parent_id,
                                    delegate: delegate).tap do |s|
      s.last_prompt = prompt
      s.status = status if status
      s.last_turn = last_turn
      s.pending_question = pending
      s.save(state_dir: tmpdir)
      rewrite(s, "updated_at" => updated_at) if updated_at
      sleep(0.01)
    end
  end

  # save stamps updated_at with now; a test that needs an old one writes it.
  def rewrite(session, fields)
    path = File.join(tmpdir, "#{session.id}.json")
    File.write(path, JSON.generate(JSON.parse(File.read(path)).merge(fields)))
  end

  def delegate_child(**) = make(parent_id: parent.id, delegate: true, **).tap { |c| started(c) }

  # As DelegateWait.mark_started leaves it: a key per child, no reply yet.
  def started(child) = cursor(child, nil)

  def cursor(child, reply_file)
    Samagotchi::Tools::DelegateCursors.update(parent.id, child.id, state_dir: tmpdir) { |c| c.with(reply_file: reply_file) }
  end

  def reply(child, text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(child.id, state_dir: tmpdir), text)
    sleep(0.002)
    Samagotchi::ReplyWait.newest_reply(child.id, state_dir: tmpdir)
  end

  def own(session)
    locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: "worker")
  end

  def of(**) = described_class.of(parent.id, state_dir: tmpdir, **)

  def state(child) = of.find { |c| c.id == child.id }.state

  describe ".of" do
    it "is empty for a session with no children" do
      parent
      make(prompt: "a stranger")
      expect(of).to eq([])
    end

    it "tells each state: waiting, running, failed, stopped, done and idle" do
      waiting = delegate_child(status: "running", pending: { id: "a1", kind: "approval", question: "Run it?" }).tap { |c| own(c) }
      running = delegate_child(status: "running").tap { |c| own(c) }
      starting = delegate_child(status: "running")
      failed = delegate_child(status: "idle", last_turn: { "outcome" => "failed" })
      errored = delegate_child(status: "error", updated_at: old)
      stopped = delegate_child(status: "idle").tap { |c| Samagotchi::Session.mark_stopped(c.id, state_dir: tmpdir) }
      done = delegate_child(status: "idle", last_turn: { "outcome" => "completed" }).tap { |c| reply(c, "all green") }
      empty = delegate_child(status: "idle", last_turn: { "outcome" => "completed" })
      canceled = delegate_child(status: "idle", last_turn: { "outcome" => "canceled" }).tap { |c| reply(c, "earlier") }
      gone = delegate_child(status: "running", updated_at: old)

      expect([waiting, running, starting, failed, errored, stopped, done, empty, canceled, gone].map { |c| state(c) })
        .to eq(%w[waiting running running failed failed stopped done idle idle idle])
      expect(of.find { |c| c.id == waiting.id }.waiting).to eq("approval")
    end

    it "gives the first line of the newest reply and whether the parent was given it" do
      told = delegate_child(status: "idle", last_turn: { "outcome" => "completed" })
      cursor(told, reply(told, "\nAll 12 specs pass\nchanged two files"))
      untold = delegate_child(status: "idle", last_turn: { "outcome" => "completed" })
      cursor(untold, reply(untold, "first"))
      reply(untold, "second reply")
      silent = delegate_child(status: "running")

      rows = of.to_h { |c| [c.id, c] }
      expect(rows[told.id]).to have_attributes(last_reply: "All 12 specs pass", reported: true)
      expect(rows[told.id].last_reply_at).to be_within(5).of(Time.now)
      expect(rows[untold.id]).to have_attributes(last_reply: "second reply", reported: false)
      expect(rows[silent.id]).to have_attributes(last_reply: nil, last_reply_at: nil, reported: false)
    end

    it "reads the branch of the child's folder: a linked worktree's own, a detached sha, none outside git" do
      root = File.realpath(tmpdir)
      main = File.join(root, "app")
      FileUtils.mkdir_p(File.join(main, ".git", "worktrees", "app-fix"))
      File.write(File.join(main, ".git", "HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(main, ".git", "worktrees", "app-fix", "HEAD"), "ref: refs/heads/fix/flaky\n")
      FileUtils.mkdir_p(File.join(root, "app-fix", "lib"))
      File.write(File.join(root, "app-fix", ".git"), "gitdir: #{File.join(main, ".git", "worktrees", "app-fix")}\n")
      FileUtils.mkdir_p(File.join(root, "detached", ".git"))
      File.write(File.join(root, "detached", ".git", "HEAD"), "0123456789abcdef0123456789abcdef01234567\n")

      on_main = delegate_child(cwd: main)
      in_worktree = delegate_child(cwd: File.join(root, "app-fix", "lib"))
      detached = delegate_child(cwd: File.join(root, "detached"))
      plain = delegate_child(cwd: root)

      branches = of.to_h { |c| [c.id, c.branch] }
      expect(branches.values_at(on_main.id, in_worktree.id, detached.id, plain.id)).to eq(["main", "fix/flaky", "01234567", nil])
    end

    it "lists forks marked as not delegates, and archived children only when asked" do
      child = delegate_child(prompt: "count the specs")
      fork = make(parent_id: parent.id, prompt: "a fork")
      archived = delegate_child(prompt: "old work")
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)

      expect(of.map { |c| [c.id, c.delegate, c.title] })
        .to contain_exactly([child.id, true, "count the specs"], [fork.id, false, "a fork"])
      expect(of(include_archived: true).find { |c| c.id == archived.id }).to have_attributes(archived: true)
    end
  end

  describe ".counts" do
    it "is zero for a session that started no child" do
      expect(described_class.counts(parent.id, state_dir: tmpdir)).to eq(described_class::Counts.none)
    end

    it "counts only the delegates in the parent's delegates.json: running, waiting and not reported" do
      delegate_child(status: "running").tap { |c| own(c) }
      delegate_child(status: "running", pending: { id: "q1", kind: "question", question: "Which?" }).tap { |c| own(c) }
      delegate_child(status: "idle", last_turn: { "outcome" => "completed" }).tap { |c| reply(c, "done, not told") }
      delegate_child(status: "idle", last_turn: { "outcome" => "completed" }).tap { |c| cursor(c, reply(c, "told")) }
      # Keys that aren't this parent's delegates: a fork passed to
      # delegate session:, a stranger, a deleted child.
      make(parent_id: parent.id, status: "running").tap { |f| own(f) }.then { |f| started(f) }
      make(status: "running").tap { |s| own(s) }.then { |s| started(s) }
      started(Struct.new(:id).new(SecureRandom.uuid))
      # A delegate not in delegates.json (from before layer 1) isn't read.
      make(parent_id: parent.id, delegate: true, status: "running").tap { |c| own(c) }

      expect(Samagotchi::SessionManager).not_to receive(:children_of)
      expect(described_class.counts(parent.id, state_dir: tmpdir).to_h).to eq(running: 1, waiting: 1, unreported: 1)
    end

    it "leaves out an archived delegate" do
      child = delegate_child(status: "idle", last_turn: { "outcome" => "completed" }).tap { |c| reply(c, "x") }
      Samagotchi::ArchiveStore.archive(child.id, state_dir: tmpdir)

      expect(described_class.counts(parent.id, state_dir: tmpdir)).to eq(described_class::Counts.none)
    end
  end
end
