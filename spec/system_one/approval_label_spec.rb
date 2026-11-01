# frozen_string_literal: true

require "samagotchi/system_one"

RSpec.describe Samagotchi::SystemOne::ApprovalLabel do
  let(:scopes) { %w[once repo] }

  def answer(index, by: nil)
    Samagotchi::QuestionAnswer.new(id: "q1", selected: [], selected_indices: index ? [index] : [], by: by)
  end

  def of(given, may: true) = described_class.of(given, scopes: scopes, parent_may_permit: -> { may })

  it "reads the user's answer as strong" do
    expect(of(answer(0))).to have_attributes(value: "allow_once", by: "user", strength: "strong")
    expect(of(answer(1))).to have_attributes(value: "allow_wide", by: "user", strength: "strong")
    expect(of(answer(2))).to have_attributes(value: "deny", by: "user", strength: "strong")
    expect(of(answer(nil))).to have_attributes(value: "deny", by: "user", strength: "strong")
  end

  it "saves a cancelled ask as itself, not an answer" do
    expect(of(nil)).to have_attributes(value: "none", by: "none", strength: nil)
  end

  it "reads a parent's allow as nothing, and its deny as weak only where it could have allowed" do
    expect(of(answer(0, by: "parent_agent"))).to be_nil
    expect(of(answer(2, by: "parent_agent"))).to have_attributes(value: "deny", by: "parent", strength: "weak")
    expect(of(answer(2, by: "parent_agent"), may: false)).to be_nil
  end

  it "has /guardrails wrong as strong" do
    expect(described_class::WRONG).to have_attributes(value: "should_have_asked", by: "user", strength: "strong")
  end

  it "saves on the run, with its question; an id from before runs and no runs are nothing" do
    store = Samagotchi::SystemOne::Runs::MemoryStore.new
    runs = Samagotchi::SystemOne::Runs.new(store: store)
    described_class.save(runs, "approvals.allow/1", described_class::WRONG)
    expect(store.lines["approvals.allow"].first).to include("kind" => "label", "run_id" => "approvals.allow/1", "question" => "allow",
                                                            "value" => "should_have_asked", "strength" => "strong")
    expect(described_class.save(runs, "0f0a6f1e", described_class::WRONG)).to be(false)
    expect(described_class.save(nil, "approvals.allow/1", described_class::WRONG)).to be_nil
  end
end
