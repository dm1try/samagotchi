# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"

# What a hook's event[:notify], event[:ask_user] and event[:stop_turn] do
# once the Engine's runtime is behind them.
RSpec.describe "The hook runtime through the Engine" do
  include_context "thinking off"

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [{ role: "model", content: "ok" }], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [])
    )
  end

  def wait_for_question(engine)
    wait_until(timeout: 2, interval: 0.005) { engine.pending_question }
  end

  describe "notify" do
    it "reaches the turn's sink and the observers as :hook_notice with the hook's label" do
      engine.register_hook(:before_turn) { |e| e[:notify].call("looks off", level: :warn) }
      sink = []
      seen = []
      engine.subscribe(observer: ->(e) { seen << e })

      engine.run_turn(session, "hi", on_event: ->(e) { sink << e })

      notice = { type: :hook_notice, hook: "turn hook", text: "looks off", level: :warn }
      expect(sink).to include(notice)
      expect(seen.find { |e| e[:type] == :hook_notice }).to include(notice)
    end

    it "reaches the observers alone without a sink (a worker's turn), at level info by default" do
      engine.register_hook(:before_turn) { |e| e[:notify].call("fyi") }
      seen = []
      engine.subscribe(observer: ->(e) { seen << e })

      engine.run_turn(session, "hi")

      expect(seen.find { |e| e[:type] == :hook_notice }).to include(text: "fyi", level: :info)
    end
  end

  describe "ask_user" do
    it "is nil at once in a non-interactive run, and opens no question" do
      result = :unset
      engine.register_hook(:before_turn) { |e| result = e[:ask_user].call(question: "which?", options: %w[a b]) }

      engine.run_turn(session, "hi")

      expect(result).to be_nil
      expect(engine.pending_question).to be_nil
    end

    it "asks through the question flow in a worker (kind hook) and returns the answer" do
      engine.interface = :worker
      result = :unset
      engine.register_hook(:before_turn) do |e|
        result = e[:ask_user].call(question: "which?", options: %w[a b], header: "known-names")
      end

      thread = Thread.new { engine.run_turn(session, "hi") }
      pending = wait_for_question(engine)
      expect(pending).to include(kind: "hook", hook: "turn hook", header: "known-names", question: "which?",
                                 options: %w[a b], multi_select: false, allow_freeform: false)
      engine.answer_question(id: pending[:id], selected: ["b"])
      thread.join(2)

      expect(result).to eq(selected: ["b"], freeform: nil, selected_indices: [1])
    end

    it "is nil when the question is dismissed" do
      engine.interface = :worker
      result = :unset
      engine.register_hook(:before_turn) { |e| result = e[:ask_user].call(question: "which?", options: %w[a b]) }

      thread = Thread.new { engine.run_turn(session, "hi") }
      pending = wait_for_question(engine)
      engine.cancel_question("dismissed", id: pending[:id])
      thread.join(2)

      expect(result).to be_nil
    end

    it "is nil when a sync handler (the REPL) answers with text instead of a choice" do
      engine.interface = :repl
      engine.set_question_sync_handler { |_pending| "some typed text" }
      result = :unset
      engine.register_hook(:before_turn) { |e| result = e[:ask_user].call(question: "which?", options: %w[a b]) }

      engine.run_turn(session, "hi")

      expect(result).to be_nil
    end

    it "is nil for options that are not 2-8 strings, without asking" do
      engine.interface = :worker
      result = :unset
      engine.register_hook(:before_turn) { |e| result = e[:ask_user].call(question: "which?", options: ["only one"]) }

      engine.run_turn(session, "hi")

      expect(result).to be_nil
      expect(engine.pending_question).to be_nil
    end
  end

  describe "stop_turn" do
    let(:engine) { Samagotchi::Engine.new(client: client) }
    let(:batch) do
      %(<|tool_call>call:execute{command: "echo one"}<tool_call|>\n<|tool_call>call:execute{command: "echo two"}<tool_call|>)
    end

    before do
      allow(client).to receive(:complete) do |_prompt, **kwargs|
        ctrl = kwargs[:cancel_controller]
        raise Samagotchi::Client::RequestCancelled.new(ctrl.reason) if ctrl&.cancelled?

        batch
      end
    end

    it "from before_tool_call denies that call and the rest of the batch, and the turn ends cancelled (hook)" do
      engine.register_hook(:before_tool_call) do |e|
        e[:stop_turn].call("no shell today") if e[:call][:content] == "echo one"
      end
      events = []

      result = engine.run_turn(session, "go", on_event: ->(e) { events << e })

      completed = events.select { |e| e[:type] == :tool_call_completed }
      expect(completed.map { |e| e.dig(:activity, :status) }).to eq(%w[blocked blocked])
      expect(completed[0][:output]).to include("the turn was stopped by turn hook: no shell today")
      expect(completed[1][:output]).to include("the turn was stopped")
      expect(events.find { |e| e[:type] == :hook_notice })
        .to include(hook: "turn hook", text: "stopped the turn: no shell today", level: :warn)
      expect(events.last).to include(type: :turn_canceled, cancellation_reason: :hook)
      expect(result.canceled?).to be(true)
    end

    it "returns true once, then false for the already cancelled turn" do
      results = []
      engine.register_hook(:before_tool_call) { |e| 2.times { results << e[:stop_turn].call("stop") } }
      events = []

      engine.run_turn(session, "go", on_event: ->(e) { events << e })

      expect(results).to eq([true, false])
      expect(events.count { |e| e[:type] == :hook_notice }).to eq(1)
    end
  end

  describe "stop_generation" do
    let(:engine) { Samagotchi::Engine.new(client: client) }

    before { allow(client).to receive(:complete).and_return("done") }

    it "is false outside a streaming generation, and from after_turn" do
      results = {}
      %i[before_turn before_generation after_generation after_turn].each do |name|
        engine.register_hook(name) { |e| results[name] = e[:stop_generation].call("loops") }
      end
      events = []

      result = engine.run_turn(session, "go", on_event: ->(e) { events << e })

      expect(results).to eq(before_turn: false, before_generation: false, after_generation: false, after_turn: false)
      expect(result.output).to eq("done")
      expect(events.none? { |e| e[:type] == :hook_notice }).to be(true)
    end
  end

  describe "steer" do
    let(:engine) { Samagotchi::Engine.new(client: client) }

    before do
      replies = [%(<|tool_call>call:execute{command: "true"}<tool_call|>), "done"]
      allow(client).to receive(:complete) { replies.shift || "done" }
    end

    it "from after_tool_call puts the text into the turn as its own user message, source the hook" do
      results = []
      engine.register_hook(:after_tool_call) { |e| results << e[:steer].call("how is it going?") }
      events = []

      engine.run_turn(session, "go", on_event: ->(e) { events << e })

      expect(results).to eq([true])
      expect(session.messages).to include(role: "user", kind: "steer", source: "turn hook", content: "how is it going?")
      expect(events.find { |e| e[:type] == :pending_input_merged })
        .to include(count: 0, content: nil, steers: [{ source: "turn hook", text: "how is it going?" }])
    end

    it "is false from after_turn and session_end (the turn is over)" do
      results = []
      engine.register_hook(:after_turn) { |e| results << e[:steer].call("late") }
      engine.register_hook(:session_end) { |e| results << e[:steer].call("later") }

      engine.run_turn(session, "go")

      expect(results).to eq([false, false])
      expect(session.messages.none? { |m| m[:kind] == "steer" }).to be(true)
    end

    it "is attributed to a bundle hook's bundle" do
      engine.instance_variable_get(:@hooks).register_bundle("check-in", :after_tool_call, hook_name: "plugin.rb") do |e|
        e[:steer].call("nudge")
      end

      engine.run_turn(session, "go")

      expect(session.messages).to include(role: "user", kind: "steer", source: "check-in", content: "nudge")
    end
  end
end
