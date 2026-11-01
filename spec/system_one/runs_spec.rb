# frozen_string_literal: true

require "samagotchi/system_one"

RSpec.describe Samagotchi::SystemOne::Runs do
  let(:question) { Samagotchi::SystemOne::Question.new(id: "pick", type: :choice, instructions: "Which?", criteria: { "a" => "first" }) }

  it "carries the judgment in a run id, and finds it again" do
    id = described_class.new_id("check-in.progress")
    expect(id).to start_with("check-in.progress/")
    expect(described_class.judgment_of(id)).to eq("check-in.progress")
  end

  it "reads no judgment from an id without one" do
    expect(described_class.judgment_of("0f0a6f1e-4f6b")).to be_nil
    expect(described_class.judgment_of(nil)).to be_nil
    expect(described_class.judgment_of("/x")).to be_nil
    expect(described_class.judgment_of("x/")).to be_nil
  end

  it "digests the wording and the criteria apart" do
    base = described_class.digests([question])
    other_criteria = described_class.digests([question.with(criteria: { "b" => "second" })])
    other_wording = described_class.digests([question.with(instructions: "Which one?")])
    expect(other_criteria["instructions_digest"]).to eq(base["instructions_digest"])
    expect(other_criteria["criteria_digest"]).not_to eq(base["criteria_digest"])
    expect(other_wording["instructions_digest"]).not_to eq(base["instructions_digest"])
    expect(other_wording["criteria_digest"]).to eq(base["criteria_digest"])
  end

  it "saves nothing without a store" do
    expect(described_class.new).not_to be_on
    expect(described_class.new.record(id: "x/1", judgment: "x", questions: [question])).to be(false)
  end

  it "leaves out nil fields" do
    store = described_class::MemoryStore.new
    described_class.new(store: store).record(id: "x/1", judgment: "x", questions: [question], host: nil, mode: "on")
    expect(store.lines["x"].first).to include("mode" => "on", "id" => "x/1").and(satisfy { |line| !line.key?("host") })
  end
end
