# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session"
require "samagotchi/turn_checkpoint"

RSpec.describe Samagotchi::TurnCheckpoint do
  let(:tmpdir) { Dir.mktmpdir("turn-checkpoint") }
  let(:history) { [{ role: "user", content: "earlier" }, { role: "model", content: "ok", display_refs: [{ "kind" => "file" }] }] }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir).tap do |s|
      s.messages = history
      s.save(state_dir: tmpdir)
      s.status = Samagotchi::Session::STATUS_RUNNING
    end
  end
  let(:now) { [100.0] }
  let(:checkpoint) { described_class.new(session: session, state_dir: tmpdir, interval: 10, clock: -> { now.first }) }
  let(:conversation) { history.map(&:dup) + [{ role: "user", content: "task" }] }

  after { FileUtils.rm_rf(tmpdir) }

  def on_disk = JSON.parse(File.read(Samagotchi::Session.session_file(session.id, state_dir: tmpdir)))

  def contents = on_disk["messages"].map { |m| m["content"] }

  before { checkpoint.begin_turn(prompt: "task") }

  it "starts the turn's overlay as the history plus the prompt, marked at iteration 0 (a kill before the first boundary)" do
    session.save(state_dir: tmpdir)
    expect(contents).to eq(%w[earlier ok task])
    expect(on_disk["interrupted_turn"]).to include("iteration" => 0)
    expect(session.messages).to eq(history)

    checkpoint.begin_turn
    session.save(state_dir: tmpdir)
    expect(contents).to eq(%w[earlier ok])
    expect(on_disk["interrupted_turn"]).to include("iteration" => 0)
  end

  it "puts the turn's enqueued_id on every mark: the first and each boundary's; none for a turn that ran no input" do
    checkpoint.begin_turn(prompt: "task", enqueued_id: "q1")
    session.save(state_dir: tmpdir)
    expect(on_disk["interrupted_turn"]).to include("enqueued_id" => "q1", "iteration" => 0)

    checkpoint.boundary(conversation, turn_id: "t1")
    expect(on_disk["interrupted_turn"]).to include("id" => "t1", "enqueued_id" => "q1", "iteration" => 1)
    expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).interrupted_turn.enqueued_id).to eq("q1")

    checkpoint.begin_turn(prompt: "next")
    checkpoint.boundary(conversation)
    expect(on_disk["interrupted_turn"]).not_to have_key("enqueued_id")
  end

  it "puts a participant's author on every mark of their turn, none on the owner's" do
    checkpoint.begin_turn(prompt: "task", enqueued_id: "q1", author: { author: "p:abc", author_name: "Alex" })
    session.save(state_dir: tmpdir)
    expect(on_disk["interrupted_turn"]).to include("author" => "p:abc")

    checkpoint.boundary(conversation, turn_id: "t1")
    expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).interrupted_turn.author).to eq("p:abc")

    checkpoint.begin_turn(prompt: "next", enqueued_id: "q2")
    checkpoint.boundary(conversation)
    expect(on_disk["interrupted_turn"]).not_to have_key("author")
  end

  it "loads a mark written without enqueued_id (an older worker's) with none" do
    mark = Samagotchi::InterruptedTurn.from_file("id" => "t1", "iteration" => 2)
    expect(mark).to have_attributes(id: "t1", iteration: 2, enqueued_id: nil)
    expect(Samagotchi::InterruptedTurn.from_file(mark.with(enqueued_id: "q1").to_file).enqueued_id).to eq("q1")
  end

  it "writes at the first boundary: the conversation so far and the mark, the session's messages untouched" do
    expect(checkpoint.boundary(conversation, turn_id: "t1")).to be(true)

    expect(contents).to eq(%w[earlier ok task])
    expect(on_disk["messages"][1]["display_refs"]).to eq([{ "kind" => "file" }])
    expect(on_disk["interrupted_turn"]).to include("id" => "t1", "iteration" => 1)
    expect(on_disk["status"]).to eq("running")
    expect(session.messages).to eq(history)
  end

  it "writes again only after the interval, keeping the newest copy for any save meanwhile" do
    checkpoint.boundary(conversation)
    conversation << { role: "tool_response", content: "r1" }
    expect(checkpoint.boundary(conversation)).to be(false)
    expect(contents).to eq(%w[earlier ok task])
    # Another save in the turn (QuestionDesk's) writes the newest copy.
    session.save(state_dir: tmpdir)
    expect(contents.last).to eq("r1")

    now[0] += 10
    conversation << { role: "tool_response", content: "r2" }
    expect(checkpoint.boundary(conversation)).to be(true)
    expect(contents.last).to eq("r2")
    expect(on_disk["interrupted_turn"]).to include("iteration" => 3)
  end

  it "writes at once with the lines the boundary merges, after the conversation" do
    checkpoint.boundary(conversation)
    line = Samagotchi::Steer::Line.new(text: "also this", source: "chi_send")

    expect(checkpoint.boundary(conversation, merging: [line])).to be(true)

    expect(on_disk["messages"].last).to include("role" => "user", "kind" => "input", "source" => "chi_send", "content" => "also this")
  end

  it "copies each message: an edit the loop makes later in place doesn't reach the copy" do
    checkpoint.boundary(conversation)
    conversation.last[:content] = "edited"
    session.save(state_dir: tmpdir)
    expect(contents.last).to eq("task")
  end

  it "does nothing with no live conversation (no turn)" do
    seeded = session.turn_checkpoint
    expect(checkpoint.boundary(nil)).to be(false)
    expect(session.turn_checkpoint).to equal(seeded)
  end

  it "is dropped as the turn ends: a save writes the session's own messages, without a mark" do
    checkpoint.boundary(conversation)
    checkpoint.end_turn
    session.status = Samagotchi::Session::STATUS_IDLE
    session.save(state_dir: tmpdir)
    expect(contents).to eq(%w[earlier ok])
    expect(on_disk["interrupted_turn"]).to be_nil
  end

  describe ".settle" do
    let(:mark) do
      Samagotchi::InterruptedTurn.new(id: "t1", started_at: "2026-10-12T10:00:00.000Z", at: "2026-10-12T10:01:30.000Z", iteration: 4)
    end

    it "ends the dead turn as canceled: its note at the tail, idle, the mark gone, last_turn as it was" do
      session.last_turn = { "outcome" => "completed", "ended_at" => "2026-10-12T09:00:00.000Z" }
      session.messages = history + [{ role: "user", content: "task" }, { role: "tool_response", content: "r1" }]
      session.interrupted_turn = mark

      expect(described_class.settle(session)).to eq(mark)

      expect(session.messages.size).to eq(5)
      expect(session.messages.first(4).map { |m| m[:content] }).to eq(%w[earlier ok task r1])
      expect(session.messages.last[:content]).to include("the previous turn was cancelled (worker-stopped) after 90s")
      expect(session.status).to eq("idle")
      expect(session.interrupted_turn).to be_nil
      # A chi send --wait whose message started the worker would read a new
      # one as its own turn's end (ReplyWait).
      expect(session.last_turn).to have_attributes(outcome: "completed", ended_at: "2026-10-12T09:00:00.000Z")
    end

    it "says no time when the mark is from the turn's first moments" do
      session.interrupted_turn = mark.with(at: "2026-10-12T10:00:00.300Z")
      described_class.settle(session)
      expect(session.messages.last[:content]).to include("cancelled (worker-stopped); no answer")
    end

    it "does nothing without a mark" do
      expect(described_class.settle(session)).to be_nil
      expect(session.messages).to eq(history)
    end

    describe "the dead turn's end under its enqueued_id (.settled_turn)" do
      let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

      it "records it as canceled (worker_stopped), for that id only, with last_turn left as it was" do
        session.interrupted_turn = mark.with(enqueued_id: "q1")
        described_class.settle(session, session_dir: dir)

        expect(described_class.settled_turn(dir, "q1"))
          .to have_attributes(outcome: "canceled", cancel_reason: "worker_stopped", enqueued_id: "q1", seconds: 90.0)
        expect(described_class.settled_turn(dir, "q2")).to be_nil
        expect(session.last_turn).to be_nil
        # Outside the input glob: no worker takes it as a message.
        expect(Samagotchi::SessionInbox.find_new_input_files(dir)).to be_empty
      end

      it "keeps a participant's turn's author in its record (whose wait it is after chi web restarts)" do
        session.interrupted_turn = mark.with(enqueued_id: "q1", author: "p:abc")
        described_class.settle(session, session_dir: dir)

        expect(described_class.settled_turn(dir, "q1"))
          .to have_attributes(outcome: "canceled", cancel_reason: "worker_stopped", author: "p:abc")
      end

      it "records nothing for a turn that ran no input, or with no session_dir" do
        session.interrupted_turn = mark
        described_class.settle(session, session_dir: dir)
        expect(Dir.exist?(File.join(dir, "input", described_class::SETTLED_DIR))).to be(false)

        session.interrupted_turn = mark.with(enqueued_id: "q1")
        described_class.settle(session)
        expect(described_class.settled_turn(dir, "q1")).to be_nil
      end

      it "reads a record it can't parse as the settle's outcome, and an id that isn't one as none" do
        FileUtils.mkdir_p(File.join(dir, "input", "settled"))
        File.write(File.join(dir, "input", "settled", "q1"), "{oops")
        expect(described_class.settled_turn(dir, "q1")).to have_attributes(outcome: "canceled", cancel_reason: "worker_stopped")
        expect(described_class.settled_turn(dir, "../q1")).to be_nil
      end

      it "records a file-delivered command's outcome by its status: completed, failed, or canceled for that reason" do
        { "c-ok" => "ok", "c-error" => "error", "c-busy" => "busy", "c-dropped" => "dropped" }.each do |id, status|
          described_class.record_command_outcome(dir, id, status: status)
        end

        expect(described_class.settled_turn(dir, "c-ok")).to have_attributes(outcome: "completed", cancel_reason: nil)
        expect(described_class.settled_turn(dir, "c-error")).to have_attributes(outcome: "failed", cancel_reason: nil)
        expect(described_class.settled_turn(dir, "c-busy")).to have_attributes(outcome: "canceled", cancel_reason: "busy")
        expect(described_class.settled_turn(dir, "c-dropped")).to have_attributes(outcome: "canceled", cancel_reason: "dropped")
      end

      it "logs a record it can't write and settles all the same" do
        session.interrupted_turn = mark.with(enqueued_id: "q1")
        allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::EACCES)
        allow(Samagotchi::Log).to receive(:warn)

        expect(described_class.settle(session, session_dir: dir)).to eq(mark.with(enqueued_id: "q1"))
        expect(session).to have_attributes(status: "idle", interrupted_turn: nil)
        expect(Samagotchi::Log).to have_received(:warn).with(:worker, "settled_turn_write_failed", error: "Errno::EACCES", msg: a_kind_of(String))
      end
    end
  end

  it "logs a write that fails and goes on" do
    allow(session).to receive(:save).and_raise(Errno::ENOSPC)
    allow(Samagotchi::Log).to receive(:warn)
    expect(checkpoint.boundary(conversation)).to be(false)
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "checkpoint_failed", error: "Errno::ENOSPC", msg: a_kind_of(String))
  end
end
