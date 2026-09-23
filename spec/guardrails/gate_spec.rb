# frozen_string_literal: true

require "samagotchi/guardrails"
require "samagotchi/hooks"

RSpec.describe Samagotchi::Guardrails::Gate do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:gate) { described_class.new(-> { hooks }) }
  let(:call) { { name: "execute", content: "ls" } }

  def evaluate = gate.evaluate(call, iteration: 1, params: 'command="ls"')

  it "allows the call when no hook votes" do
    verdict = evaluate
    expect(verdict).to be_allow
    expect(verdict.call).to eq(call)
  end

  it "denies with the hook's reason" do
    hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "nope" }
    verdict = evaluate
    expect(verdict).to be_deny
    expect(verdict.reason).to eq("nope")
  end

  it "returns the call a hook replaced" do
    hooks.register(:before_tool_call) { |e| e[:call] = { name: "execute", content: "pwd" } }
    expect(evaluate.call).to eq({ name: "execute", content: "pwd" })
  end

  it "allows when there is no registry" do
    expect(described_class.new(-> {}).evaluate(call, iteration: 1, params: "")).to be_allow
  end

  it "does not change the caller's call hash" do
    hooks.register(:before_tool_call) { |e| e[:call][:content] = "pwd" }
    evaluate
    expect(call[:content]).to eq("ls")
  end
end
