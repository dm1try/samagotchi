# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/child_reports"
require "samagotchi/owner_lock"
require "samagotchi/session_manager"
require "samagotchi/archive_store"
require "samagotchi/tools/delegate_result"
require "samagotchi/relay_desk"

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
  end

  # A turn's end as its worker saves it: idle, last_turn moved on.
  def end_turn(session, outcome: "completed", pending_question: nil)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = "idle"
    s.pending_question = pending_question
    s.last_turn = { "outcome" => outcome, "ended_at" => Time.now.iso8601(6) }
    s.save(state_dir: tmpdir)
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

    it "rings the parent parent.json names, read fresh, over the one the child holds in memory, and wakes it" do
      held = Samagotchi::Session.load(child.id, state_dir: tmpdir)
      moved_to = make
      Samagotchi::Session.reparent(child.id, to: moved_to.id, from: parent.id, state_dir: tmpdir)

      path = described_class.ring(held, why: "turn_end", state_dir: tmpdir, wake: woken)

      expect(held.parent_id).to eq(parent.id)
      expect(File.dirname(path)).to eq(File.join(Samagotchi::Session.session_dir(moved_to.id, state_dir: tmpdir), "children"))
      expect(rings).to be_empty
      expect(wakes).to eq([moved_to.id])
    end

    it "never rings for a fork or a session with no parent" do
      fork = make(parent_id: parent.id)
      expect(ring(fork)).to be_nil
      expect(ring(parent)).to be_nil
      expect(rings).to be_empty
    end

    describe ".await_wakes" do
      # The default wake: SessionManager.wake_for_report on a thread.
      def ring_on_thread
        described_class.ring(Samagotchi::Session.load(child.id, state_dir: tmpdir), why: "crash", state_dir: tmpdir)
      end

      it "waits for the wake threads its rings started, once" do
        allow(Samagotchi::SessionManager).to receive(:wake_for_report) do |id, **|
          sleep(0.1) # sleep-ok: a slow wake, still running when await_wakes joins it
          (@wakes ||= []) << id
        end
        ring_on_thread

        expect(described_class.await_wakes).to eq(0)
        expect(wakes).to eq([parent.id])
        expect(described_class.await_wakes(0)).to eq(0)
      end

      it "waits at most its timeout for a wake that doesn't end" do
        gate = Queue.new
        allow(Samagotchi::SessionManager).to receive(:wake_for_report) { gate.pop }
        ring_on_thread
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect(described_class.await_wakes(0.1)).to eq(1)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      ensure
        gate << true
      end
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

    it "wakes the chain's next link for an archived parent a continue moved its children from" do
      Samagotchi::ArchiveStore.archive(parent.id, state_dir: tmpdir)
      link = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: parent.id)
      link.save(state_dir: tmpdir)

      expect(wake).to eq(:woken)
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(link.id, state_dir: tmpdir)
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
      expect(taken.first.origin).to eq(Samagotchi::TurnOrigin.new(client_id: "child:#{child.id[0, 8]}"))
      # Taken in this turn: not handed out again at the next boundary.
      expect(box.waiting?).to be(false)
      expect(box.take).to eq([])

      box.commit
      expect(rings).to be_empty
      expect(cursor.reply_file).to end_with(".txt")
      # The model's delegate_result now has nothing new either.
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to include("no reply yet")
    end

    it "clears the follow-up's turn (DelegateCursor#turn) with the end it reports, so a later wait doesn't repeat it" do
      Samagotchi::Tools::DelegateWait.mark_turn(parent.id, child.id, "x1", state_dir: tmpdir)
      Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(child.id, state_dir: tmpdir), "found it",
                                            enqueued_id: "x1")
      end_turn(child)
      ring

      box = reports
      box.take
      box.commit
      expect(cursor.turn).to be_nil
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to include("no reply yet")
    end

    it "reports the follow-up turn's own reply, not a newer one of a turn queued behind it, then the queued one" do
      dir = Samagotchi::Session.session_dir(child.id, state_dir: tmpdir)
      Samagotchi::Tools::DelegateWait.mark_turn(parent.id, child.id, "x1", state_dir: tmpdir)
      Samagotchi::SessionInbox.write_output(dir, "follow-up answer", enqueued_id: "x1")
      Samagotchi::SessionInbox.write_output(dir, "queued answer", enqueued_id: "q1")
      end_turn(child)
      ring

      box = reports
      expect(box.take.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfollow-up answer"])
      box.commit
      ring
      expect(reports.take.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nqueued answer"])
    end

    # The follow-up y1 was merged as a steer into a turn starting as it
    # went in (its own turn never comes): that turn's reply is its report,
    # once, whether the absorbing turn has an id or none.
    [["with an id", "a1"], ["with no id (a wake or reminder turn)", nil]].each do |shape, absorbing|
      it "reports a follow-up merged into another turn #{shape} once, with that turn's reply" do
        dir = Samagotchi::Session.session_dir(child.id, state_dir: tmpdir)
        Samagotchi::WorkerSidecar.new(port: 1, features: %w[turn_ids]).write(dir)
        Samagotchi::Tools::DelegateWait.mark_turn(parent.id, child.id, "y1", state_dir: tmpdir)
        Samagotchi::SessionInbox.write_output(dir, "absorbing answer", enqueued_id: absorbing)
        end_turn(child)
        ring

        box = reports
        expect(box.take.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nabsorbing answer"])
        box.commit
        expect(cursor.turn).to be_nil
        ring
        expect(reports.take).to eq([])
      end
    end

    it "has nothing to report after delegate_result (or wait: true) gave the reply; the ring goes" do
      write_reply(child, "found it")
      end_turn(child)
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to end_with("found it")
      ring

      expect(reports.take).to eq([])
      expect(rings).to be_empty
    end

    it "doesn't give a reply twice when delegate_result waits after a report took it but before that turn commits" do
      write_reply(child, "found it")
      end_turn(child)
      ring
      box = reports
      report = box.take.fetch(0)
      reply_path = File.join(Samagotchi::ReplyWait.reply_dir(child.id, state_dir: tmpdir), report.after.reply_file)

      result = Samagotchi::Tools::DelegateResult.call(session: child.id, timeout: 0, peers: peers)

      expect(result).to include("already reported", report.after.reply_file)
      expect(result.ref_path).to eq(reply_path)
      box.commit
      expect(Samagotchi::Tools::DelegateResult.call(session: child.id, timeout: 0, peers: peers)).to include("no reply yet")
    end

    it "retries a reserved report after a new parent worker takes ownership" do
      write_reply(child, "found it")
      end_turn(child)
      ring
      reports.take
      expect(cursor.report_claim.file).to end_with(".txt")

      restarted = reports
      expect(restarted.take.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfound it"])
      restarted.commit
    end

    it "still reports the reply after a wait that timed out or was canceled: neither moves the cursor" do
      own(child)
      Samagotchi::Session.load(child.id, state_dir: tmpdir).tap { |s| s.status = "running" }.save(state_dir: tmpdir)
      before = cursor
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0)).to include("no reply yet after 0 s")
      canceled = Samagotchi::Tools::Peers.new(session_id: parent.id, state_dir: tmpdir, cancelled: -> { true })
      expect(Samagotchi::Tools::DelegateWait.call(child.id, peers: canceled, timeout: 5)).to include("wait canceled")
      expect(cursor).to eq(before)

      write_reply(child, "done after the wait")
      end_turn(child)
      ring

      taken = reports.take
      expect(taken.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\ndone after the wait"])
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

    # P4: a hook's question the parent may usefully answer under the
    # child's strategy is reported; an approval isn't (the relay takes it).
    it "reports the model's question, the step-limit continue and a hook's question the parent may answer, not an approval" do
      own(child)
      end_turn(child, pending_question: { id: "a1", kind: "approval", question: "Run rm?" })
      ring(why: "question")
      expect(reports.take).to eq([])
      expect(rings).to be_empty

      end_turn(child, pending_question: { id: "h1", kind: "hook", header: "Cost cap", question: "Spent $5.",
                                          options: %w[Continue Stop], effects: %w[spend deny] })
      ring(why: "question")
      text = reports.take.first.text
      expect(text).to include("status: question\nChild #{child.id} is waiting for an answer (hook): Cost cap")
      expect(text).to include("    1. Continue\n    2. Stop\n")
      expect(text).to include("answer: chi answer #{child.id} --question h1")

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
      expect(cursor.without_claim).to eq(moved.without_claim)
    end

    describe "a ring left in the predecessor (a continue moved the child as it rang)" do
      let(:link) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", continues: parent.id)
                           .tap { |s| s.save(state_dir: tmpdir) }
      end

      def link_reports = Samagotchi::ChildReports.new(session_id: link.id, state_dir: tmpdir, predecessor: parent.id)

      it "is the new link's report, once, for a child moved to it" do
        write_reply(child, "found it")
        end_turn(child)
        Samagotchi::Session.reparent(child.id, to: link.id, from: parent.id, state_dir: tmpdir)
        Samagotchi::Tools::DelegateCursors.merge(link.id, Samagotchi::Tools::DelegateCursors.read(parent.id, state_dir: tmpdir),
                                                 state_dir: tmpdir)
        Samagotchi::SessionInbox.write_ring(parent_dir, child_id: child.id, why: "turn_end")

        reports = link_reports
        expect(reports.waiting?).to be(true)
        expect(reports.take.map(&:child_id)).to eq([child.id])
        reports.commit

        expect(rings).to be_empty
        expect(link_reports.waiting?).to be(false)
        expect(link_reports.take).to eq([])
      end

      it "is neither reported nor deleted for a child that wasn't moved" do
        write_reply(child, "found it")
        end_turn(child)
        ring

        reports = link_reports
        expect(reports.waiting?).to be(false)
        expect(reports.take).to eq([])
        reports.commit
        expect(rings.size).to eq(1)
      end
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

  # P4: the report-vs-relay decision is made on the parent's side in three
  # places, all on the child's strategy: the delegate report
  # (ChildReports), the wait (DelegateWait.call) and the look at the other
  # children (DelegateRelay::Others#waiting). A child tightened to hard on
  # its own, under config.yml's soft, goes to the relay on each.
  describe "the routing twin (child's own hard under config soft)" do
    let(:cost_cap) do
      { id: "h1", kind: "hook", hook: "cost-cap", header: "Cost cap", question: "Spent $5.",
        options: %w[Continue Stop], effects: %w[spend deny], status: "pending" }
    end
    let(:cards) { [] }
    let(:relay) do
      desk = Samagotchi::RelayDesk.new
      opened = cards
      Struct.new(:relay_desk) do
        define_method(:open_question) do |fields, watch:|
          opened << fields
          { error: "cancelled", reason: "child_gone" }
        end
      end.new(desk)
    end

    before do
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("soft")
      allow(Samagotchi::WorkerLink).to receive(:client).and_return(nil)
      own(child)
      s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
      s.parent_answers = "hard"
      s.save(state_dir: tmpdir)
      started
      end_turn(child, pending_question: cost_cap)
    end

    it "relays on all three paths" do
      waiting = Samagotchi::Tools::DelegateRelay::Others.new(parent_id: parent.id, except: "none", relay: relay,
                                                             state_dir: tmpdir, on_outcome: ->(*) {}).waiting
      expect(waiting.map { |id, q| [id, q.id] }).to eq([[child.id, "h1"]])

      peers = Samagotchi::Tools::Peers.new(session_id: parent.id, cwd: "/w", state_dir: tmpdir, cancelled: -> { false },
                                           relay: relay)
      Samagotchi::Tools::DelegateWait.call(child.id, peers: peers, timeout: 0.3, poll_interval: 0.05, owner_grace: 0.3)
      expect(cards.map { |c| c[:kind] }).to eq(["hook"])

      ring(why: "question")
      expect(reports.take.first.relay&.id).to eq("h1")
    end
  end
end
