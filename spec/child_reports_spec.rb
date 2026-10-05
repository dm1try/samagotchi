# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/child_reports"
require "samagotchi/owner_lock"
require "samagotchi/session_manager"
require "samagotchi/archive_store"

# A delegate child's news reaching its parent: the child rings (ChildRing),
# the parent reads the rings and asks the child what happened (ChildReports).
RSpec.describe "delegate reports" do
  let(:tmpdir) { Dir.mktmpdir("child-reports") }
  let(:locks) { [] }
  let(:parent) { make }
  let(:child) { make(parent_id: parent.id, delegate: true) }
  let(:parent_dir) { Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir) }
  let(:mode) { ["wake"] }

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports") { mode[0] }
  end

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(parent_id: nil, delegate: false, status: "idle")
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", parent_id: parent_id,
                                    delegate: delegate).tap do |s|
      s.status = status
      s.save(state_dir: tmpdir)
    end
  end

  def own(session, kind: "worker")
    locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: kind)
  end

  def write_reply(session, text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  # A turn's end as its worker saves it: idle, last_turn moved on.
  def end_turn(session, outcome: "completed", pending_question: nil)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = "idle"
    s.pending_question = pending_question
    s.last_turn = { "outcome" => outcome, "ended_at" => Time.now.iso8601(6) }
    s.save(state_dir: tmpdir)
    sleep(0.002)
  end

  def ring(session = child, why: "turn_end")
    Samagotchi::ChildRing.ring(Samagotchi::Session.load(session.id, state_dir: tmpdir), why: why, state_dir: tmpdir,
                                                                                         wake: woken)
  end

  def woken = @woken ||= ->(id) { (@wakes ||= []) << id }
  def wakes = @wakes || []

  def rings = Samagotchi::SessionInbox.find_ring_files(parent_dir)

  def reports(parent_session = parent)
    Samagotchi::ChildReports.new(session_id: parent_session.id, state_dir: tmpdir)
  end

  def cursor(c = child) = Samagotchi::Tools::DelegateCursors.get(parent.id, c.id, state_dir: tmpdir)

  # The child as the delegate tool leaves it: a baseline taken before its first turn.
  def started(c = child)
    Samagotchi::Tools::DelegateWait.mark_started(parent.id, c, state_dir: tmpdir)
  end

  describe Samagotchi::ChildRing do
    it "drops a ring naming the child into the parent's children/ and wakes a parent with no worker" do
      path = ring
      expect(File.dirname(path)).to eq(File.join(parent_dir, "children"))
      expect(Samagotchi::SessionInbox.read_ring(path)).to include(child_id: child.id, why: "turn_end")
      expect(wakes).to eq([parent.id])
    end

    it "doesn't wake a parent whose worker runs (it sees the ring on its next pass)" do
      own(parent)
      ring
      expect(wakes).to be_empty
      expect(rings.size).to eq(1)
    end

    it "rings but doesn't wake in queue mode, and does nothing at all when off" do
      mode[0] = "queue"
      ring
      expect([rings.size, wakes]).to eq([1, []])

      mode[0] = "off"
      expect(ring).to be_nil
      expect(rings.size).to eq(1)
    end

    it "never rings for a fork or a session with no parent" do
      fork = make(parent_id: parent.id)
      expect(ring(fork)).to be_nil
      expect(ring(parent)).to be_nil
      expect(rings).to be_empty
    end

    it "leaves no orphan dir for a deleted parent" do
      child
      File.delete(Samagotchi::Session.session_file(parent.id, state_dir: tmpdir))
      expect(ring).to be_nil
      expect(Dir.exist?(parent_dir)).to be(false)
    end
  end

  describe "SessionManager.wake_for_report" do
    before { allow(Samagotchi::SessionManager).to receive(:resume_session) }

    def wake(session = parent) = Samagotchi::SessionManager.wake_for_report(session.id, state_dir: tmpdir)

    it "resumes an idle parent with no worker" do
      expect(wake).to eq(:woken)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(parent.id, state_dir: tmpdir)
    end

    it "leaves a stopped, archived, scratch, owned or deleted parent alone" do
      Samagotchi::Session.mark_stopped(parent.id, state_dir: tmpdir)
      expect(wake).to eq(:stopped)

      archived = make
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)
      expect(wake(archived)).to eq(:archived)

      scratch = make
      scratch.scratch = true
      scratch.save(state_dir: tmpdir)
      expect(wake(scratch)).to eq(:scratch)

      repl = make
      own(repl, kind: "tui")
      expect(wake(repl)).to eq(:owned)

      gone = make
      File.delete(Samagotchi::Session.session_file(gone.id, state_dir: tmpdir))
      expect(wake(gone)).to eq(:gone)

      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
      expect(Samagotchi::Session.stopped_marker?(parent.id, state_dir: tmpdir)).to be(true)
    end
  end

  describe Samagotchi::ChildReports do
    before { started }

    it "turns a ring into the reply delegate_result would give, and commits it: cursor moved on, ring gone" do
      write_reply(child, "found it")
      end_turn(child)
      ring

      box = reports
      expect(box.waiting?).to be(true)
      taken = box.take
      expect(taken.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfound it"])
      expect(taken.first.line).to eq(Samagotchi::Steer::Line.new(text: taken.first.text, source: "delegate_report"))
      expect(taken.first.origin).to eq(client_id: "child:#{child.id[0, 8]}")
      # Taken in this turn: not handed out again at the next boundary.
      expect(box.waiting?).to be(false)
      expect(box.take).to eq([])

      box.commit
      expect(rings).to be_empty
      expect(cursor.reply_file).to end_with(".txt")
      # The model's delegate_result now has nothing new either.
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to include("no reply yet")
    end

    it "has nothing to report after delegate_result (or wait: true) gave the reply; the ring goes" do
      write_reply(child, "found it")
      end_turn(child)
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to end_with("found it")
      ring

      expect(reports.take).to eq([])
      expect(rings).to be_empty
    end

    it "makes one report of two rings from one child" do
      write_reply(child, "the reply")
      end_turn(child)
      ring(why: "question")
      ring

      taken = reports.take
      expect(taken.size).to eq(1)
      expect(taken.first.rings.size).to eq(2)
    end

    it "reports two children apart, each with its own session line" do
      other = make(parent_id: parent.id, delegate: true)
      started(other)
      [child, other].each_with_index do |c, i|
        write_reply(c, "reply #{i}")
        end_turn(c)
        ring(c)
      end

      expect(reports.take.map { |r| r.text.lines.first.strip }).to contain_exactly("session: #{child.id}", "session: #{other.id}")
    end

    it "reports a child's turn that failed as no_reply (status failed)" do
      end_turn(child, outcome: "failed")
      ring

      expect(reports.take.map(&:text)).to eq(["session: #{child.id}\nstatus: failed\nthe child's turn failed; its session shows what happened"])
    end

    it "reports a crashed child" do
      Samagotchi::Session.mark_error(child.id, reason: "boom", state_dir: tmpdir)
      ring(why: "crash")

      expect(reports.take.first.text).to include("status: error\nthe child's worker failed: boom")
    end

    it "reports the model's question and the step-limit continue, not an approval or a hook's question" do
      own(child)
      end_turn(child, pending_question: { id: "a1", kind: "approval", question: "Run rm?" })
      ring(why: "question")
      expect(reports.take).to eq([])
      expect(rings).to be_empty

      end_turn(child, pending_question: { id: "c1", kind: "continue", header: "Step limit", question: "Continue it?",
                                          options: %w[Continue Stop] })
      ring(why: "question")
      expect(reports.take.first.text).to include("status: question\nChild #{child.id} is waiting for an answer (continue)")
    end

    it "loses nothing when the turn that took a report fails, or the worker goes: the next one reports it once" do
      write_reply(child, "found it")
      end_turn(child)
      ring

      box = reports
      expect(box.take.size).to eq(1)
      box.release # the turn failed
      expect(rings.size).to eq(1)
      expect(box.take.size).to eq(1)

      # The worker exits before the turn ends: a new one reads the same ring.
      fresh = reports
      expect(fresh.take.size).to eq(1)
      fresh.commit
      expect(reports.take).to eq([])
    end

    it "doesn't repeat a reply for a respawned parent (the cursor is on disk)" do
      write_reply(child, "found it")
      end_turn(child)
      ring
      box = reports
      box.take
      box.commit

      ring # a spurious second ring, read by a new worker
      expect(reports.take).to eq([])
    end

    it "keeps a cursor the model moved itself (delegate_result) during the turn" do
      write_reply(child, "first")
      end_turn(child)
      ring
      box = reports
      box.take

      write_reply(child, "second")
      end_turn(child)
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to end_with("second")
      moved = cursor
      box.commit
      expect(cursor).to eq(moved)
    end

    it "ignores a ring from a session that isn't this parent's child" do
      stranger = make(parent_id: make.id, delegate: true)
      Samagotchi::SessionInbox.write_ring(parent_dir, child_id: stranger.id, why: "turn_end")

      expect(reports.take).to eq([])
      expect(rings).to be_empty
    end

    it "reads nothing when off" do
      write_reply(child, "found it")
      end_turn(child)
      ring
      mode[0] = "off"
      box = reports
      expect([box.waiting?, box.take]).to eq([false, []])
      expect(rings.size).to eq(1)
    end

    def peers
      Samagotchi::Tools::Peers.new(session_id: parent.id, state_dir: tmpdir, cancelled: -> { false })
    end
  end
end
