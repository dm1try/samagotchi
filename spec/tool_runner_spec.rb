# frozen_string_literal: true

require "samagotchi/tool_runner"
require "samagotchi/hooks"

# ToolRunner's per-call contract around the before_tool_call veto. The loop
# level (text the model gets, both loops) is in
# spec/llm/tool_call_wrapper_parity_spec.rb.
RSpec.describe Samagotchi::ToolRunner do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:dispatched) { [] }
  let(:kernel) do
    k = Struct.new(:hooks, :dispatched) do
      def dispatch_tool_call(call)
        dispatched << call
        { output: "[#{call[:name]}]\nran", activity: { tool: call[:name], status: "ok" } }
      end
    end
    k.new(hooks, dispatched)
  end
  let(:events) { [] }
  let(:runner) { described_class.new(kernel) }
  let(:call) { { name: "execute", content: "ls" } }

  def run(c = call)
    runner.run(c, iteration: 1, call_index: 1, call_count: 1,
                  on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
  end

  it "dispatches an unvetoed call" do
    result = run
    expect(result[:output]).to eq("[execute]\nran")
    expect(dispatched).to eq([call])
  end

  it "does not dispatch a blocked call and gives the model the veto text" do
    hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
    result = run
    expect(dispatched).to be_empty
    expect(result[:output]).to eq("[execute] Error: blocked by guardrail: nope")
    expect(result[:activity]).to include(status: "blocked")
  end

  it "uses a default reason when a hook blocks without one" do
    hooks.register(:before_tool_call) { |e| e[:blocked] = true }
    expect(run[:output]).to eq("[execute] Error: blocked by guardrail: blocked by hook")
  end

  it "dispatches a call a hook replaced" do
    hooks.register(:before_tool_call) { |e| e[:call] = { name: "execute", content: "pwd" } }
    run
    expect(dispatched).to eq([{ name: "execute", content: "pwd" }])
  end

  it "passes the before event its call, params, and an unset veto" do
    seen = nil
    hooks.register(:before_tool_call) { |e| seen = e.dup }
    run
    expect(seen).to include(type: :before_tool_call, iteration: 1, call: call, blocked: false, block_reason: nil)
    expect(seen[:params]).to include("ls")
  end

  it "still dispatches when a hook raises" do
    hooks.register(:before_tool_call) { |_e| raise "boom" }
    run
    expect(dispatched).to eq([call])
  end

  describe "sticky verdict" do
    it "keeps a veto a later hook tries to undo" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
      hooks.register(:before_tool_call) { |e| e[:blocked] = false; e[:block_reason] = nil }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to eq("[execute] Error: blocked by guardrail: nope")
    end

    it "denies through the verdict API with the deny text for the model" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no listing today") }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to eq(
        "[execute] Error: denied by guardrail (hook): no listing today. The user was not asked. " \
        "Do not retry it or reach the same result another way; ask the user how to proceed."
      )
      expect(result[:activity]).to include(status: "blocked", guardrail: { verdict: "deny", decided_by: "hook" })
    end

    it "names the rule and its source in the deny text" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("pushes commits", rule: "git-push", source: "bundle guardrails") }
      expect(run[:output]).to start_with("[execute] Error: denied by guardrail (rule git-push, bundle guardrails): pushes commits.")
    end

    it "denies an ask when no one can approve it" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("really?") }
      result = run
      expect(dispatched).to be_empty
      expect(result[:output]).to include("denied by guardrail (hook): really? No one to approve it.")
    end

    it "lets hooks see the verdict so far" do
      seen = nil
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("x") }
      hooks.register(:before_tool_call) { |e| seen = [e[:guardrail].decision, e[:blocked]] }
      run
      expect(seen).to eq([:deny, true])
    end
  end

  it "denies the call when the gate itself fails" do
    allow_any_instance_of(Samagotchi::Guardrails::Gate).to receive(:evaluate).and_raise(RuntimeError, "bug")
    result = run
    expect(dispatched).to be_empty
    expect(result[:output]).to start_with("[execute] Error: denied by guardrail (core): the guardrail check failed: RuntimeError: bug.")
  end

  describe "tool_call_started" do
    it "is emitted after the hooks, with the call they replaced" do
      order = []
      hooks.register(:before_tool_call) do |e|
        order << (events.any? { |ev| ev[:type] == :tool_call_started } ? :started_before : :started_after)
        e[:call] = { name: "execute", content: "pwd" }
      end
      run
      expect(order).to eq([:started_after])
      expect(events.first).to include(type: :tool_call_started, call: { name: "execute", content: "pwd" })
      expect(events.first[:params]).to include("pwd")
    end

    it "is emitted for a denied call too, before tool_call_completed" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true }
      run
      expect(events.map { |e| e[:type] }).to eq(%i[tool_call_started tool_call_completed])
    end
  end
end
