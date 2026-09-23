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

  describe "votes" do
    it "keeps the strictest vote: deny beats a later ask" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no") }
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("maybe") }
      verdict = evaluate
      expect(verdict.decision).to eq(:deny)
      expect(verdict.reason).to eq("no")
    end

    it "lets a deny override an earlier ask" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("maybe", scopes: %w[once]) }
      hooks.register(:before_tool_call) { |e| e[:guardrail].deny!("no", rule: "r1") }
      verdict = evaluate
      expect([verdict.decision, verdict.reason, verdict.rule]).to eq([:deny, "no", "r1"])
    end

    it "keeps the first of two equal votes" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("first") }
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("second") }
      expect(evaluate.reason).to eq("first")
    end

    it "carries the ask's scopes" do
      hooks.register(:before_tool_call) { |e| e[:guardrail].ask!("maybe", scopes: %w[once session]) }
      expect(evaluate.scopes).to eq(%w[once session])
    end

    it "folds the legacy flag in after each hook, as a legacy deny" do
      hooks.register(:before_tool_call) { |e| e[:blocked] = true; e[:block_reason] = "old" }
      hooks.register(:before_tool_call) { |e| e[:blocked] = false }
      verdict = evaluate
      expect(verdict).to be_deny
      expect(verdict).to be_legacy
      expect(verdict.reason).to eq("old")
    end

    it "counts a fail_closed bundle hook that raises as a deny" do
      hooks.register_bundle("b", :before_tool_call, hook_name: "g.rb") do |e|
        raise "boom"
      rescue StandardError => err
        Samagotchi::Hooks::BundleLoader.handle_error("b", "g.rb", "fail_closed", true, e, err)
      end
      hooks.register(:before_tool_call) { |e| e[:blocked] = false }
      expect(evaluate).to be_deny
    end
  end
end

RSpec.describe Samagotchi::Guardrails::Gate, "context and targets" do
  let(:hooks) { Samagotchi::Hooks::Registry.new }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: "/tmp", session_id: "s1", interface: :worker) }
  let(:gate) { described_class.new(-> { hooks }, context_lookup: -> { context }) }

  it "gives hooks the context and the call's targets" do
    seen = nil
    hooks.register(:before_tool_call) { |e| seen = e.slice(:context, :targets) }
    gate.evaluate({ name: "execute", content: "ls", cwd: "sub" }, iteration: 1, params: "")
    expect(seen[:context]).to include(cwd: "/tmp", session_id: "s1", interface: :worker)
    expect(seen[:targets]).to include(command: "ls", cwd: "/tmp/sub")
  end

  it "rebuilds the targets from a replaced call" do
    hooks.register(:before_tool_call) { |e| e[:call] = { name: "execute", content: "pwd" } }
    verdict = gate.evaluate({ name: "execute", content: "ls" }, iteration: 1, params: "")
    expect(verdict.targets.command).to eq("pwd")
    expect(verdict.context).to be(context)
  end
end
