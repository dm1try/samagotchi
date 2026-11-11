# frozen_string_literal: true

require "samagotchi/turn_context"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"
require_relative "support/fake_chat_adapter"

# The tracker by itself, wired into the Engine through real turns: off asks
# nothing, on reads once after each turn that did work and recorded no move,
# and the owner's next turn cancels a read still out.
RSpec.describe Samagotchi::Engine do
  include_context "thinking off"

  let(:dir) { Dir.mktmpdir("objectives-track-engine") }
  let(:state_dir) { File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:setting) { "on" }
  let(:asks) { Queue.new }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, model_name: "Gemma-4B-it").tap do |e|
      e.instance_variable_set(:@session_state_dir, state_dir)
      e.interface = :worker
      allow(e).to receive(:effective_model_name).and_return("model")
      allow(e).to receive(:ask_objective_track) do |request, cancel_controller:, **|
        asks << cancel_controller
        answer.call(request, cancel_controller)
      end
    end
  end
  let(:answer) { ->(_request, _cancel) { "O1: progress — a file was written" } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: dir).tap do |s|
      s.messages = [Samagotchi::ContextNote.message(note_id: "n", text: "O1 aim", source: "objectives", header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                                    objectives: { "next" => 2, "items" => [{ "id" => "O1", "text" => "aim", "status" => "active" }] })]
      s.save(state_dir: state_dir)
    end
  end

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("objectives.tracker").and_return(setting)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("off")
  end

  after do
    engine.shutdown
    FileUtils.rm_rf(dir)
  end

  def stage = engine.send(:objectives_stage)

  def settle
    thread = engine.instance_variable_get(:@side_judgments).thread(Samagotchi::ObjectivesTrack::SOURCE)
    join!(thread, "the tracker's read") if thread
  end

  def write_step(n) = FakeChatAdapter.tools(["w#{n}", "write", { "path" => File.join(dir, "f#{n}.txt"), "content" => "x" }])

  def move_step(n) = FakeChatAdapter.tools(["m#{n}", "objectives", { "id" => "O1", "note" => "wrote f#{n}" }])

  def turn(*steps)
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(*steps, FakeChatAdapter.text("Done.")))
    allow(engine).to receive(:backend_for).and_return(backend)
    engine.run_turn(session, "write a file")
    settle
  end

  def tracks = Samagotchi::ObjectivesTrack::STORE.lines(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))

  context "with objectives.tracker off (the default)" do
    let(:setting) { "off" }

    it "asks nothing after five work turns and writes no file" do
      5.times { |n| turn(write_step(n)) }

      expect(File.exist?(File.join(dir, "f4.txt"))).to be(true)
      expect(asks).to be_empty
      expect(tracks).to be_empty
    end
  end

  it "reads once per turn that did work and recorded no move, none after a turn with a move" do
    turn(write_step(1))
    turn(write_step(2), move_step(2))
    turn(write_step(3))

    expect(asks.size).to eq(2)
    expect(tracks.count { |line| line["readings"] }).to eq(2)
  end

  it "its side request is the owner's, counted under its own kind, even when a participant's turn runs as it ends" do
    allow(engine).to receive(:turn_context).and_return(Samagotchi::TurnContext.none(author: "p:abc"))

    expect(engine.side_author(Samagotchi::ObjectivesTrack::SOURCE)).to be_nil
    expect(Samagotchi::ObjectivesTrack::SOURCE).not_to eq(Samagotchi::ObjectivesCheck::SOURCE)
  end

  context "with a read still out at the next turn" do
    let(:released) { Queue.new }
    let(:answer) do
      lambda { |_request, cancel|
        cancel.on_cancel { released << true }
        released.pop
        raise Samagotchi::LLM::RequestCancelled, "cancelled"
      }
    end

    it "the owner's next turn cancels it, and it ends with no answer and no card" do
      cards = []
      allow(engine).to receive(:show_card).and_wrap_original do |original, **card|
        cards << card if card[:title] == Samagotchi::ObjectivesTrack::TITLE
        original.call(**card)
      end
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(write_step(1), FakeChatAdapter.text("Done.")))
      allow(engine).to receive(:backend_for).and_return(backend)
      engine.run_turn(session, "write a file")
      cancel = asks.pop
      expect(cancel.cancelled?).to be(false)

      turn(FakeChatAdapter.text("just a reply"))

      expect(cancel.reason).to eq(:new_turn)
      expect(tracks.last["readings"].values.map { |r| r["reading"] }).to eq(%w[no_answer])
      expect(cards).to be_empty
    end

    it "a wake turn (no prompt, a turn-start note) cancels it too" do
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(write_step(1), FakeChatAdapter.text("Done.")))
      allow(engine).to receive(:backend_for).and_return(backend)
      engine.run_turn(session, "write a file")
      cancel = asks.pop

      session.messages += [Samagotchi::ContextNote.message(note_id: "w", text: "child report", source: "delegate").merge(turn_start: true)]
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("Noted.")))
      allow(engine).to receive(:backend_for).and_return(backend)
      engine.run_turn(session, nil, continue: true, origin: Samagotchi::TurnOrigin.new(client_id: "delegate"))
      settle

      expect(cancel.reason).to eq(:new_turn)
      expect(tracks.last).to include("cancelled" => true)
    end
  end
end
