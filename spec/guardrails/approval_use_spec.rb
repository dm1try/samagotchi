# frozen_string_literal: true

require "samagotchi/turn_context"
require "samagotchi/guardrails/approval_use"
require "samagotchi/guardrails/verdict"
require "samagotchi/guardrails/context"
require "samagotchi/guardrails/child_boundary"

RSpec.describe Samagotchi::Guardrails::ApprovalUse do
  def ask(rule: "git-push", fresh: false)
    v = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push" }).ask!("pushes", rule: rule, source: "config")
    v.fresh_ask = true if fresh
    v
  end

  let(:owner) { Samagotchi::TurnContext.none }
  let(:participant) { Samagotchi::TurnContext.none(author: "p:g1") }

  it "lets an owner's ask use every stored scope" do
    expect(described_class.policy(ask, owner)).to eq(:all)
    expect(described_class.scopes(ask, owner)).to eq(%w[session repo rule])
  end

  # Fail closed: only a turn known to be the owner's uses every scope.
  it "lets a call with no turn, or one that can't say whose it is, use only this session's approvals" do
    expect(described_class.policy(ask, nil)).to eq(:session)
    expect(described_class.policy(ask, Object.new)).to eq(:session)
  end

  it "lets a call whose judged context names a participant use only this session's, whatever the turn says" do
    verdict = ask
    verdict.context = Samagotchi::Guardrails::Context.new(origin: { client_id: "participant:g1", author: "p:g1" })
    expect(described_class.policy(verdict, owner)).to eq(:session)
    verdict.context = Samagotchi::Guardrails::Context.new(origin: { client_id: "web:x" })
    expect(described_class.policy(verdict, owner)).to eq(:all)
  end

  it "lets a participant's ask use only this session's approvals" do
    expect(described_class.policy(ask, participant)).to eq(:session)
    expect(described_class.scopes(ask, participant)).to eq(%w[session])
  end

  it "lets a child-boundary ask use only this session's approvals, whoever's turn it is" do
    expect(described_class.policy(ask(rule: "child-boundary"), owner)).to eq(:session)
    expect(described_class.policy(ask(rule: "child-boundary"), participant)).to eq(:session)
  end

  it "names the child boundary's rule" do
    expect(described_class::SESSION_ONLY_RULES).to eq([Samagotchi::Guardrails::ChildBoundary::RULE])
  end

  it "lets a fresh ask use none" do
    expect(described_class.policy(ask(fresh: true), owner)).to eq(:none)
    expect(described_class.policy(ask(fresh: true), participant)).to eq(:none)
    expect(described_class.scopes(ask(fresh: true), owner)).to eq([])
  end
end
