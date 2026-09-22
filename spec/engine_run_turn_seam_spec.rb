# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

# What Engine#run_turn has to offer before the interactive TUI can drive its
# turns through it (Phase R2 of the shared-session plan).
RSpec.describe Samagotchi::Engine, "#run_turn as the TUI seam" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { described_class.new(mode: :assist, client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:activity) { { action: "running command", tool: "execute", params: 'command="ls"', status: "ok" } }

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def kernel_result(**overrides)
    Samagotchi::KernelLoop::Result.new(
      output: "done", conversation: [{ role: "model", content: "done" }], exhausted: false,
      pending_tool_calls: false, tool_activity: [], canceled: false, **overrides
    )
  end

  def events_of(**kwargs)
    events = []
    engine.run_turn(session, kwargs.delete(:prompt) || "hi", on_event: ->(e) { events << e }, **kwargs)
    events
  end

  describe "turn_summary on :turn_completed" do
    it "carries the native loop's tool activity, context status and continuation flags" do
      context_status = { est_pct: 12.5, bucket: "low" }
      allow(kernel).to receive(:run).and_return(
        kernel_result(exhausted: true, pending_tool_calls: true, tool_activity: [activity], context_status: context_status)
      )

      completed = events_of.find { |e| e[:type] == :turn_completed }

      expect(completed[:result]).to be_a(Samagotchi::LLM::ModelResult)
      expect(completed[:turn_summary]).to eq(
        output: "done", exhausted: true, resumable: true, pending_tool_calls: true,
        tool_activity: [activity], context_status: context_status
      )
      expect(JSON.parse(JSON.generate(completed[:turn_summary]))).to include("resumable" => true)
    end

    it "is also available on the returned result" do
      allow(kernel).to receive(:run).and_return(kernel_result(tool_activity: [activity]))

      result = engine.run_turn(session, "hi")

      expect(result.tool_activity).to eq([activity])
      expect(result.pending_tool_calls?).to be(false)
    end
  end

  describe "continue: true" do
    it "runs the existing conversation without appending a prompt" do
      session.messages = [{ role: "system", content: "old" }, { role: "user", content: "go" }, { role: "tool_response", content: "r" }]
      session.last_prompt = "go"
      sent = nil
      allow(kernel).to receive(:run) { |messages, **| sent = messages; kernel_result }

      events = events_of(prompt: "ignored", continue: true)

      expect(sent.drop(1)).to eq([{ role: "user", content: "go" }, { role: "tool_response", content: "r" }])
      expect(sent.first[:role]).to eq("system")
      expect(session.last_prompt).to eq("go")
      expect(events.first).to include(type: :turn_started, prompt: nil, continue: true)
    end

    it "keeps :turn_started unchanged for a normal turn" do
      allow(kernel).to receive(:run).and_return(kernel_result)

      expect(events_of.first).to eq(type: :turn_started, session_id: session.id, prompt: "hi")
    end
  end

  it "does not append [No response] to a canceled turn" do
    allow(kernel).to receive(:run).and_return(
      kernel_result(output: "", conversation: [{ role: "user", content: "hi" }], canceled: true, cancellation_reason: :ctrl_c)
    )

    engine.run_turn(session, "hi")

    expect(session.messages).to eq([{ role: "user", content: "hi" }])
  end

  describe "Interrupt" do
    it "keeps the prompt in the session, emits :turn_canceled and re-raises" do
      allow(kernel).to receive(:run).and_raise(Interrupt)
      events = []

      expect { engine.run_turn(session, "hi", on_event: ->(e) { events << e }) }.to raise_error(Interrupt)

      expect(session.messages.map { |m| m[:role] }).to eq(%w[system user])
      expect(session.messages.last[:content]).to eq("hi")
      expect(events.last).to eq(type: :turn_canceled, cancellation_reason: :ctrl_c)
      expect(engine.turn_running?).to be(false)
      expect(engine.metrics.snapshot[:cancellations]).to eq(1)
    end
  end

  describe "system prompt stability" do
    it "reuses the first turn's system prompt even when the memory index changes" do
      index = "v1"
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) { index }
      sent = []
      allow(kernel).to receive(:run) { |messages, **| sent << messages.first[:content]; kernel_result(conversation: messages + [{ role: "model", content: "done" }]) }

      engine.run_turn(session, "one")
      index = "v2"
      engine.run_turn(session, "two")

      expect(sent[1]).to eq(sent[0])
      expect(sent[0]).to include("v1")
    end

    it "rebuilds it after a model switch" do
      allow(kernel).to receive(:sync_profile_from_model!)
      allow(kernel).to receive(:sync_model_key!)
      sent = []
      allow(kernel).to receive(:run) { |messages, **| sent << messages.first[:content]; kernel_result(conversation: messages) }

      engine.run_turn(session, "one")
      engine.switch_model!("Qwen3-14B")
      engine.run_turn(session, "two")

      expect(sent[1]).not_to eq(sent[0])
      expect(sent[1]).to include("<tools>")
    end
  end

  describe "session messages API" do
    before { engine.session = session }

    it "appends copies of out-of-turn messages" do
      session.messages = [{ role: "system", content: "s" }]
      extra = { role: "user", content: "!(ls)\nout" }

      engine.append_messages([extra])
      extra[:content] = "mutated"

      expect(session.messages).to eq([{ role: "system", content: "s" }, { role: "user", content: "!(ls)\nout" }])
    end

    it "rolls back to a checkpoint" do
      session.messages = [{ role: "system", content: "s" }]
      checkpoint = engine.messages_checkpoint
      engine.append_messages([{ role: "user", content: "later" }])

      engine.rollback_to(checkpoint)

      expect(session.messages).to eq([{ role: "system", content: "s" }])
    end

    it "requires a current session" do
      expect { described_class.new(mode: :assist, client: client, kernel: kernel).append_messages([]) }
        .to raise_error(ArgumentError, /no current session/)
    end
  end
end
