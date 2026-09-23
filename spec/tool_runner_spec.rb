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

  # Pinned before the guardrail work (G0a); G1 changes both on purpose.
  describe "today's behaviour, changed by G1" do
    it "lets a later hook undo an earlier veto" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
      hooks.register(:before_tool_call) { |e| e[:blocked] = false }
      run
      expect(dispatched).to eq([call])
    end

    it "emits tool_call_started before the hooks, with the original call" do
      order = []
      hooks.register(:before_tool_call) do |e|
        order << (events.any? { |ev| ev[:type] == :tool_call_started } ? :started_before : :started_after)
        e[:call] = { name: "execute", content: "pwd" }
      end
      run
      expect(order).to eq([:started_before])
      expect(events.first).to include(type: :tool_call_started, call: call)
    end
  end
end
