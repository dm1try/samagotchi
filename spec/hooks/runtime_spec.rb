# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/hooks"
require "samagotchi/kernel_loop"
require "samagotchi/session"

# What a hook's event[:notify], event[:ask_user] and event[:stop_turn] do
# once the Engine's runtime is behind them.
RSpec.describe "The hook runtime through the Engine" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    original_thinking = ENV["THINKING_MODE"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["THINKING_MODE"] = "false"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    ENV["THINKING_MODE"] = original_thinking
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client, kernel: kernel) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [{ role: "model", content: "ok" }], exhausted: false,
                                         pending_tool_calls: false, tool_activity: [])
    )
  end

  def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def wait_for_question(engine)
    deadline = mono + 2
    sleep(0.005) while engine.pending_question.nil? && mono < deadline
    engine.pending_question
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
    let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client) }
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
end
