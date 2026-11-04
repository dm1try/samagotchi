# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"
require_relative "support/fake_chat_adapter"

# System 1 on the objectives, wired into the Engine: what reaches it from a real
# turn and a real note, whose turns don't, and that the prompt never changes.
RSpec.describe Samagotchi::Engine do
  include_context "thinking off"

  let(:dir) { Dir.mktmpdir("objectives-audit-engine") }
  let(:state_dir) { File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:mode) { "audit" }
  let(:asks) { Queue.new }
  let(:system_one) { instance_double(Samagotchi::SystemOne::Client, host: "judge", model: "jev", mode: "audit") }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) do
    described_class.new(client: client, kernel: kernel, model_name: "Gemma-4B-it").tap do |e|
      e.instance_variable_set(:@session_state_dir, state_dir)
      allow(e).to receive(:effective_model_name).and_return("model")
    end
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: dir).tap do |s|
      s.messages = [Samagotchi::ContextNote.message(note_id: "n", text: "O1 aim", source: "objectives", header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                                    objectives: { "next" => 2, "items" => [{ "id" => "O1", "text" => "aim", "status" => "active" }] })]
      s.save(state_dir: state_dir)
    end
  end
  let(:long_prompt) { "Please also move the coffee order to the new payment provider" }
  let(:long_answer) { "Answer. #{"Words here. " * 60}" }

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("objectives.system_one").and_return(mode)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("off")
    allow(system_one).to receive(:ask) do |state:, **|
      asks << state
      { "affects" => Samagotchi::SystemOne::Answer.new(id: "affects", type: :noul, noul: 0.7) }
    end
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
  end

  after do
    engine.shutdown
    FileUtils.rm_rf(dir)
  end

  def side = engine.instance_variable_get(:@side_judgments)

  def settle
    %i[objectives_incoming objectives_outgoing].each do |kind|
      thread = side.thread(kind)
      join!(thread, "the #{kind} asks") if thread
    end
  end

  def turn(prompt, author: nil, client_id: nil)
    Struct.new(:session, :prompt, :origin).new(session, prompt, Samagotchi::TurnOrigin.new(author: author, client_id: client_id))
  end

  def result(text) = Struct.new(:text).new(text)

  def runs(judgment)
    Dir.glob(File.join(dir, "system_one", "runs", judgment, "*.jsonl")).flat_map { |file| File.readlines(file).map { |line| JSON.parse(line) } }
       .select { |line| line["kind"] == "run" }
  end

  it "saves an owner's message and answer as runs chi judgments reads, on their own judgments" do
    engine.send(:audit_objectives_incoming, turn(long_prompt))
    settle
    engine.send(:audit_objectives_outgoing, turn(long_prompt), result(long_answer))
    settle

    expect(runs("objectives.incoming").map { |run| run["state"] }).to eq([{ "objective" => "aim", "message" => long_prompt }])
    expect(runs("objectives.outgoing").first).to include("asked" => true, "mode" => "audit", "session_id" => session.id, "session_model" => "model")
  end

  it "a note added between turns is incoming, the list's own isn't" do
    engine.add_context_note(session, { note_id: "a", text: long_prompt, source: "peer" })
    settle
    engine.add_context_note(session, { note_id: "b", text: "O1 aim", source: "objectives", header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                       objectives: { "next" => 2, "items" => [{ "id" => "O1", "text" => "aim", "status" => "active" }] } })
    settle

    expect(runs("objectives.incoming").size).to eq(1)
  end

  it "a participant's turn is never sent and never saved" do
    engine.send(:audit_objectives_incoming, turn(long_prompt, author: "p:abc"))
    engine.send(:audit_objectives_outgoing, turn(long_prompt, author: "p:abc"), result(long_answer))
    settle

    expect(asks).to be_empty
    expect(Samagotchi::SystemOne::Client).not_to have_received(:from_config)
  end

  it "a reminder's or a delegate's turn prompt isn't a person's message" do
    engine.send(:audit_objectives_incoming, turn(long_prompt, client_id: "reminder"))
    engine.send(:audit_objectives_incoming, turn(long_prompt, client_id: "delegate"))
    settle
    expect(asks).to be_empty

    engine.send(:audit_objectives_incoming, turn(long_prompt, client_id: "web:tab"))
    settle
    expect(asks.size).to eq(1)
  end

  it "a check's side request is the owner's even when a participant's turn runs as it ends" do
    allow(engine).to receive(:turn_running?).and_return(true)
    engine.instance_variable_get(:@guardrail_wiring).begin_turn(Samagotchi::TurnOrigin.new(author: "p:abc"))

    expect(engine.side_author(Samagotchi::ObjectivesCheck::SOURCE)).to be_nil
    expect(engine.side_author("other")).to eq("p:abc")
  end

  it "with saving off, no ask is made" do
    allow(Samagotchi::Config).to receive(:get).with("system_one.runs").and_return("off")

    engine.send(:audit_objectives_incoming, turn(long_prompt))
    settle

    expect(asks).to be_empty
  end

  context "with the setting off (the default)" do
    let(:mode) { "off" }

    it "asks nothing and builds no client" do
      engine.send(:audit_objectives_incoming, turn(long_prompt))
      engine.send(:audit_objectives_outgoing, turn(long_prompt), result(long_answer))
      engine.add_context_note(session, { note_id: "a", text: long_prompt, source: "peer" })
      settle

      expect(asks).to be_empty
      expect(Samagotchi::SystemOne::Client).not_to have_received(:from_config)
      expect(Dir.exist?(File.join(dir, "system_one"))).to be(false)
    end
  end

  it "a real turn reaches both, its answer after it has been stored" do
    backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text(long_answer)))
    allow(engine).to receive(:backend_for).and_return(backend)

    engine.run_turn(session, long_prompt)
    settle

    expect(runs("objectives.incoming").size).to eq(1)
    expect(runs("objectives.outgoing").size).to eq(1)
    expect(session.messages.map { |m| m[:role].to_s }.last(2)).to eq(%w[user model])
  end
end
