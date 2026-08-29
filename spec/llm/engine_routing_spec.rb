# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe "Engine#run_turn routed through ModelBackend (Phase 1 seam)" do
  around do |example|
    original = ENV["SAMAGOTCHI_MODEL"]
    ENV["SAMAGOTCHI_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }

  def build_engine(**overrides)
    Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel, **overrides)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  it "returns a ModelResult with output identical to the native loop" do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(
        output: "hello back",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
        tool_activity: []
      )
    )
    returned = build_engine(profile: "gemma4").run_turn(make_session, "hi")

    expect(returned).to be_a(Samagotchi::LLM::ModelResult)
    expect(returned.output).to eq("hello back")
    expect(returned.tool_calls).to be_nil
  end

  it "emits turn_canceled (not turn_completed) for a canceled kernel result" do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(
        output: "", conversation: [], tool_activity: [],
        canceled: true, cancellation_reason: :user_interrupt
      )
    )
    events = []
    build_engine(profile: "gemma4").run_turn(make_session, "hi", on_event: ->(e) { events << e })

    expect(events.map { |e| e[:type] }).to include(:turn_canceled)
    expect(events.map { |e| e[:type] }).not_to include(:turn_completed)
    expect(events.find { |e| e[:type] == :turn_canceled }[:cancellation_reason]).to eq(:user_interrupt)
  end

  it "appends the [No response] placeholder for an empty output" do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "", conversation: [], tool_activity: [])
    )
    session = make_session
    build_engine(profile: "gemma4").run_turn(session, "hi")

    expect(session.messages.last).to eq({ role: "model", content: "[No response]" })
  end
end
