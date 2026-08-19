# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe Samagotchi::Engine do
  around do |example|
    original_model = ENV["SAMAGOTCHI_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    original_skip = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    ENV["SAMAGOTCHI_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    example.run
    ENV["SAMAGOTCHI_MODEL"] = original_model
    ENV["THINKING_MODE"] = original_thinking
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = original_skip
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }

  def build_engine(**overrides)
    described_class.new(mode: :assist, client: client, kernel: kernel, **overrides)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  describe "system prompt construction" do
    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    it "builds a system prompt that identifies the assistant and embeds tool declarations" do
      engine = build_engine(profile: "gemma4")
      prompt = engine.system_prompt
      expect(prompt).to include("You are Chi")
      expect(prompt).to include("declaration:execute")
      expect(prompt).to include("declaration:web_fetch")
    end

    it "exposes the same base prompt via the class helper" do
      helper = described_class.system_prompt_for("gemma4")
      engine = build_engine(profile: "gemma4")
      expect(helper).to eq(engine.send(:assist_system_prompt))
    end
  end

  describe "memory injection" do
    it "injects requested memories into the system prompt" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4", memories: ["my_note"])
      prompt = engine.system_prompt
      expect(prompt).to include("memory name: my_note")
      expect(prompt).to include("BODY-my_note")
    end

    it "returns no explicit memory section when no memories are requested" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      engine = build_engine(profile: "gemma4")
      expect(engine.send(:explicit_memory_section)).to be_nil
    end
  end

  describe "#run_turn" do
    let(:result) do
      Samagotchi::KernelLoop::Result.new(
        output: "hello back",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
    end

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    end

    it "returns the kernel Result and updates the session" do
      allow(kernel).to receive(:run).and_return(result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      returned = engine.run_turn(session, "hi")

      expect(returned).to be(result)
      expect(session.last_prompt).to eq("hi")
      expect(session.messages).to eq(result.conversation)
    end

    it "emits turn_started, forwards raw kernel events unchanged, then turn_completed" do
      events = []
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        cb = kwargs[:on_stream_event]
        cb.call(type: :generation_started, iteration: 1)
        cb.call(type: :generation_completed, iteration: 1, content: "hello back")
        result
      end
      session = make_session
      engine = build_engine(profile: "gemma4")

      engine.run_turn(session, "hi", on_event: proc { |event| events << event })

      types = events.map { |e| e[:type] }
      expect(types.first).to eq(:turn_started)
      expect(types.last).to eq(:turn_completed)
      expect(types).to include(:generation_started, :generation_completed)

      # Raw kernel events are forwarded unchanged.
      expect(events.find { |e| e[:type] == :generation_completed })
        .to eq(type: :generation_completed, iteration: 1, content: "hello back")

      # Higher-level Engine events carry turn boundaries + session id.
      expect(events.find { |e| e[:type] == :turn_started })
        .to include(session_id: session.id, prompt: "hi")
      expect(events.find { |e| e[:type] == :turn_completed }[:result]).to be(result)
    end

    it "emits turn_canceled (not turn_completed) when the result is canceled" do
      canceled_result = Samagotchi::KernelLoop::Result.new(
        output: "",
        conversation: [],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: [],
        canceled: true,
        cancellation_reason: "user_interrupt"
      )
      events = []
      allow(kernel).to receive(:run).and_return(canceled_result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      engine.run_turn(session, "hi", on_event: proc { |event| events << event })

      types = events.map { |e| e[:type] }
      expect(types).to include(:turn_canceled)
      expect(types).not_to include(:turn_completed)
      expect(events.find { |e| e[:type] == :turn_canceled }[:cancellation_reason]).to eq("user_interrupt")
    end

    it "does not raise when the event sink raises" do
      allow(kernel).to receive(:run).and_return(result)
      session = make_session
      engine = build_engine(profile: "gemma4")

      expect {
        engine.run_turn(session, "hi", on_event: proc { |_event| raise "boom" })
      }.not_to raise_error
    end
  end
end
