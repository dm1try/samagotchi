# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe "Engine#run_turn routed through ModelBackend (Phase 1 seam)" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }

  def build_engine(**overrides)
    Samagotchi::Engine.new(client: client, kernel: kernel, **overrides)
  end

  def make_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
  end

  describe ":native path (NativeBackend around the KernelLoop)" do
    it "returns a ModelResult with output identical to the native loop" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run).and_return(
        Samagotchi::KernelLoop::Result.new(
          output: "hello back",
          conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
          tool_activity: []
        )
      )
      # No provider override → :native → NativeBackend
      returned = build_engine(profile: "gemma4").run_turn(make_session, "hi")

      expect(returned).to be_a(Samagotchi::LLM::ModelResult)
      expect(returned.output).to eq("hello back")
      expect(kernel).to have_received(:run)
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

      expect(session.messages[-2]).to eq({ role: "model", content: "[No response]" })
      expect(session.messages.last).to include(role: "system", kind: "turn_note")
    end

    it "passes max_iterations through to KernelLoop#run" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run) { |*args, **kwargs|
        expect(args.first).to be_an(Array)
        expect(kwargs[:max_iterations]).to eq(42)
        expect(kwargs[:max_tool_output_chars]).to eq(500)
        expect(kwargs[:on_stream_event]).to be_a(Proc)
        Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [], tool_activity: [])
      }
      build_engine(profile: "gemma4").run_turn(make_session, "hi", max_iterations: 42, max_tool_output_chars: 500)
    end
  end

  describe "chat path (backend is ChatLoop)" do
    let(:backend) { instance_double(Samagotchi::LLM::ChatLoop) }

    def build_engine_with_backend(**overrides)
      engine = build_engine(**overrides)
      allow(engine).to receive(:backend).and_return(backend)
      engine
    end

    it "delegates to @backend.complete and returns the ModelResult" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      model_result = Samagotchi::LLM::ModelResult.new(
        text: "cloud response",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "cloud response" }]
      )
      allow(backend).to receive(:complete).and_return(model_result)

      returned = build_engine_with_backend(profile: "gemma4").run_turn(make_session, "hi")

      expect(returned).to eq(model_result)
      expect(backend).to have_received(:complete)
    end

    it "emits turn_canceled for a canceled backend result" do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      model_result = Samagotchi::LLM::ModelResult.new(
        text: "",
        canceled: true, cancellation_reason: :user_interrupt,
        conversation: []
      )
      allow(backend).to receive(:complete).and_return(model_result)

      events = []
      build_engine_with_backend(profile: "gemma4").run_turn(make_session, "hi", on_event: ->(e) { events << e })

      expect(events.map { |e| e[:type] }).to include(:turn_canceled)
      expect(events.map { |e| e[:type] }).not_to include(:turn_completed)
    end
  end
end
