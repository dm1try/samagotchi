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

  it "logs a write that fails and goes on" do
    allow(session).to receive(:save).and_raise(Errno::ENOSPC)
    allow(Samagotchi::Log).to receive(:warn)
    expect(checkpoint.boundary(conversation)).to be(false)
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "checkpoint_failed", error: "Errno::ENOSPC", msg: a_kind_of(String))
  end
end
