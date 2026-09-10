# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe Samagotchi::Engine do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    original_skip = ENV["SAMAGOTCHI_SKIP_AGENT_MD"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    ENV.delete("SAMAGOTCHI_SKIP_AGENT_MD")
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
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

    it "includes rg guidance in the system prompt when rg is available" do
      engine = build_engine(profile: "gemma4")
      allow(engine).to receive(:rg_available?).and_return(true)
      expect(engine.system_prompt).to include("prefer `rg` (ripgrep) over `grep`")
    end

    it "omits rg guidance from the system prompt when rg is not available" do
      engine = build_engine(profile: "gemma4")
      allow(engine).to receive(:rg_available?).and_return(false)
      expect(engine.system_prompt).not_to include("prefer `rg` (ripgrep) over `grep`")
    end
  end

  describe "memory injection" do
    before do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    end

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

    it "merges the config.yml memories baseline with the --memory list (config first, deduped)" do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[baseline_a baseline_b])
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4", memories: ["baseline_b, cli_only"])

      expect(engine.instance_variable_get(:@requested_memories)).to eq(%w[baseline_a baseline_b cli_only])

      prompt = engine.system_prompt
      expect(prompt).to include("memory name: baseline_a")
      expect(prompt).to include("memory name: cli_only")
      expect(prompt.scan("memory name: baseline_b").size).to eq(1)
    end

    it "uses only the config baseline when --memory is not given" do
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[only_from_config])
      allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil|
        name.to_s.empty? ? "" : "BODY-#{name}"
      end
      engine = build_engine(profile: "gemma4")

      expect(engine.instance_variable_get(:@requested_memories)).to eq(%w[only_from_config])
      expect(engine.system_prompt).to include("memory name: only_from_config")
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

      expect(returned).to be_a(Samagotchi::LLM::ModelResult)
      expect(returned.conversation).to eq(result.conversation)
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
      expect(events.find { |e| e[:type] == :turn_completed }[:result]).to be_a(Samagotchi::LLM::ModelResult)
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

    it "forwards tool_call_completed output and output_truncated to the event sink" do
      engine = build_engine(profile: "gemma4")
      events = []
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        kwargs[:on_stream_event]&.call(
          type: :tool_call_completed,
          output: "[read]\nhi",
          output_truncated: false,
          activity: { action: "reading file", tool: "read", params: 'path="x"', status: "ok" }
        )
      end

      engine.run_turn(make_session, "hi", on_event: proc { |event| events << event })

      completed = events.find { |event| event[:type] == :tool_call_completed }
      expect(completed[:output]).to eq("[read]\nhi")
      expect(completed[:output_truncated]).to be(false)
    end
  end

  describe "#subscribe / persistent observer" do
    let(:result) do
      Samagotchi::KernelLoop::Result.new(
        output: "hello back",
        conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
        exhausted: false,
        pending_tool_calls: false,
        tool_activity: []
      )
    end

    # Stub the kernel so it emits a small set of raw events on each run.
    def stub_kernel_events
      allow(kernel).to receive(:run) do |_messages, **kwargs|
        cb = kwargs[:on_stream_event]
        cb.call(type: :generation_started, iteration: 1)
        cb.call(type: :generation_completed, iteration: 1, content: "hello back")
        result
      end
    end

    # Stub the kernel, run a turn with a no-op on_event sink, and return nothing.
    def run_turn_with_kernel_events(engine, session, prompt)
      stub_kernel_events
      engine.run_turn(session, prompt, on_event: ->(_event) {})
    end

    it "delivers every event across multiple turns to a single observer" do
      events = []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { events << event })
      session = make_session

      2.times { |i| run_turn_with_kernel_events(engine, session, "hi #{i}") }

      expect(events.map { |e| e[:type] }.count(:turn_started)).to eq(2)
      expect(events.map { |e| e[:type] }.count(:turn_completed)).to eq(2)
      expect(events.map { |e| e[:type] }).to include(:generation_started, :generation_completed)
      # event_seq is strictly increasing and consecutive across turns.
      seqs = events.map { |e| e[:event_seq] }
      expect(seqs.first).to eq(1)
      expect(seqs).to eq((1..seqs.length).to_a)
    end

    it "delivers identical events to multiple subscribers" do
      first, second = [], []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { first << event })
      engine.subscribe(observer: ->(event) { second << event })
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")
      expect(first).to eq(second)
      expect(first).not_to be_empty
    end

    it "exposes a monotonic engine-local event_count that increments per emitted event" do
      engine = build_engine(profile: "gemma4")
      expect(engine.event_count).to eq(0)
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")
      expect(engine.event_count).to eq(4) # turn_started + 2 raw kernel + turn_completed
    end

    it "stops delivery after unsubscribe but leaves other subscribers intact" do
      dropped, kept = [], []
      engine = build_engine(profile: "gemma4")
      handle = engine.subscribe(observer: ->(event) { dropped << event })
      engine.subscribe(observer: ->(event) { kept << event })
      session = make_session

      run_turn_with_kernel_events(engine, session, "hi 1")
      handle.unsubscribe
      run_turn_with_kernel_events(engine, session, "hi 2")

      expect(dropped.map { |e| e[:type] }).to eq(%i[turn_started generation_started generation_completed turn_completed])
      expect(kept.map { |e| e[:type] }).to eq((%i[turn_started generation_started generation_completed turn_completed] * 2))
    end

    it "isolates a raising observer so the turn completes and others still receive" do
      other = []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(_event) { raise "boom" })
      engine.subscribe(observer: ->(event) { other << event })
      session = make_session

      expect { run_turn_with_kernel_events(engine, session, "hi") }.not_to raise_error
      expect(other.map { |e| e[:type] }).to include(:turn_started, :turn_completed)
    end

    it "leaves on_event: un-sequenced while the observer receives a sequenced copy" do
      on_events, observer_events = [], []
      engine = build_engine(profile: "gemma4")
      engine.subscribe(observer: ->(event) { observer_events << event })
      stub_kernel_events
      session = make_session
      engine.run_turn(session, "hi", on_event: ->(event) { on_events << event })

      expect(on_events.count).to eq(observer_events.count)
      expect(on_events.first).not_to have_key(:event_seq)
      expect(observer_events.first).to have_key(:event_seq)
      expect(on_events.map { |e| e[:type] }).to eq(observer_events.map { |e| e[:type] })
    end

    it "does not deliver past events to a subscriber added after a turn ran" do
      engine = build_engine(profile: "gemma4")
      session = make_session
      run_turn_with_kernel_events(engine, session, "hi")

      events = []
      engine.subscribe(observer: ->(event) { events << event })
      run_turn_with_kernel_events(engine, session, "hi again")

      expect(events.map { |e| e[:type] }).to eq(%i[turn_started generation_started generation_completed turn_completed])
    end

    it "unsubscribe(nil) on the engine does not raise" do
      engine = build_engine(profile: "gemma4")
      expect { engine.unsubscribe(handle: nil) }.not_to raise_error
    end

    describe "#session_state_snapshot" do
      it "includes a metrics snapshot key carrying per-session analytics" do
        engine = build_engine(profile: "gemma4")
        snap = engine.session_state_snapshot
        expect(snap).to have_key(:metrics)
        expect(snap[:metrics]).to be_a(Hash)
        expect(snap[:metrics][:turns]).to eq(0)
      end
    end
  end
end
