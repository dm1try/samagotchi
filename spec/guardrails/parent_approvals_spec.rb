# frozen_string_literal: true

require "spec_helper"
require "samagotchi/guardrails/parent_approvals"

# What a parent agent (chi answer) may allow on an approval: the one rule
# the CLI checks before posting and the worker checks again.
RSpec.describe Samagotchi::Guardrails::ParentApprovals do
  let(:approval) do
    { id: "a1", kind: "approval",
      options: ["Allow once", "Allow this call for the session", "Allow rule spike-ask in this directory", "Deny"],
      approval: { tool: "execute", scopes: %w[once session rule] } }
  end

  def refusal(pending, indices, setting)
    described_class.refusal(pending, indices, setting: setting)
  end

  it "lets a deny through whatever the setting: the Deny option, no option (text alone)" do
    %w[off once].each do |setting|
      expect(refusal(approval, [3], setting)).to be_nil
      expect(refusal(approval, [], setting)).to be_nil
    end
  end

  it "refuses every allow with off, and all but the once scope with once" do
    [0, 1, 2].each { |index| expect(refusal(approval, [index], "off")).to eq(:off) }
    expect(refusal(approval, [0], "once")).to be_nil
    [1, 2].each { |index| expect(refusal(approval, [index], "once")).to eq(:once_only) }
  end

  it "checks the scope by index, never by label" do
    relabeled = approval.merge(options: ["Allow once", "Allow once", "Allow once", "Deny"])
    expect(refusal(relabeled, [1], "once")).to eq(:once_only)
    no_once = approval.merge(options: ["Allow once", "Deny"], approval: { scopes: %w[session] })
    expect(refusal(no_once, [0], "once")).to eq(:once_only)
  end

  it "refuses a mix of deny and allow (a multi-select answer), and any unknown setting as off" do
    expect(refusal(approval, [3, 0], "off")).to eq(:off)
    expect(refusal(approval, [3, 1], "once")).to eq(:once_only)
    expect(refusal(approval, [0], "always")).to eq(:off)
    expect(refusal(approval, [0], nil)).to eq(:off)
  end

  it "fails closed when the scopes are missing, empty or malformed: only the last option, Deny, passes" do
    [nil, [], "once", [nil], [1], %w[once session rule extra]].each do |scopes|
      pending = approval.merge(approval: { tool: "execute", scopes: scopes })
      [0, 1, 2].each do |index|
        expect(refusal(pending, [index], "once")).to eq(:once_only), "scopes #{scopes.inspect}, option #{index}"
      end
      expect(refusal(pending, [3], "once")).to be_nil
    end
    expect(refusal(approval.except(:approval), [0], "once")).to eq(:once_only)
    expect(refusal(approval.merge(approval: "x"), [0], "off")).to eq(:off)
  end

  it "treats a last option that isn't Deny, or an index it can't place, as an allow" do
    pending = approval.merge(options: ["Allow once", "Allow always"], approval: {})
    expect(refusal(pending, [1], "once")).to eq(:once_only)
    expect(refusal(approval, [nil], "once")).to eq(:once_only)
    expect(refusal(approval, [9], "off")).to eq(:off)
  end

  it "reads string keys (a session file) and an approval without a kind" do
    pending = { "kind" => "approval", "options" => approval[:options], "approval" => { "scopes" => %w[once session rule] } }
    expect(refusal(pending, [0], "once")).to be_nil
    expect(refusal(pending, [1], "once")).to eq(:once_only)
    expect(refusal(approval.except(:kind), [1], "off")).to eq(:off)
  end

  it "has nothing to say about a question that isn't an approval" do
    question = { id: "q1", kind: "hook", options: %w[Yes No] }
    expect(refusal(question, [0], "off")).to be_nil
    expect(refusal(question.except(:kind), [0], "off")).to be_nil
  end

  it "says how to get it allowed" do
    expect(described_class.message(:off, "abc")).to eq(
      "allowing a tool call is up to the user: approve it in the web or chi --attach abc; " \
      "deny it with --option Deny --text WHY"
    )
    expect(described_class.message(:once_only, "abc")).to start_with(
      "only Allow once (guardrails.parent_approvals: once) can be given here: approve it in the web"
    )
  end

  it "is a config.yml setting only: the parent's environment can't change it" do
    env = { "SAMAGOTCHI_GUARDRAILS_PARENT_APPROVALS" => "once" }
    expect(Samagotchi::Config.resolve("guardrails.parent_approvals", file_data: {}, env: env)).to eq("off")
    file = { "guardrails" => { "parent_approvals" => "once" } }
    expect(Samagotchi::Config.resolve("guardrails.parent_approvals", file_data: file, env: {})).to eq("once")
  end
end
