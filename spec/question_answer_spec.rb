# frozen_string_literal: true

require "json"
require "samagotchi/question_answer"

RSpec.describe Samagotchi::QuestionAnswer do
  let(:answer) { described_class.new(id: "q1", selected: ["A"], selected_indices: [0]) }
  let(:parent) { described_class.new(id: "q1", selected: ["A"], selected_indices: [0], by: "parent_agent") }

  it "has a user's answer's shape as a Hash, in member order, without :by" do
    expect(answer.to_h).to eq(id: "q1", selected: ["A"], freeform: nil, selected_indices: [0])
    expect(answer.to_h.keys).to eq(%i[id selected freeform selected_indices])
  end

  it "carries a parent agent's :by last" do
    expect(parent.to_h).to eq(id: "q1", selected: ["A"], freeform: nil, selected_indices: [0], by: "parent_agent")
    expect(parent.to_h.keys.last).to eq(:by)
  end

  it "generates the ask_user_question tool result's bytes from #to_h" do
    expect(JSON.generate(answer.to_h)).to eq('{"id":"q1","selected":["A"],"freeform":null,"selected_indices":[0]}')
  end

  it "knows a parent agent's answer" do
    expect(parent).to be_parent_agent
    expect(answer).not_to be_parent_agent
  end

  it "defaults freeform, selected_indices and by" do
    bare = described_class.new(id: "q1", selected: [])

    expect([bare.freeform, bare.selected_indices, bare.by]).to eq([nil, [], nil])
  end

  it "needs an id and selected" do
    expect { described_class.new(selected: []) }.to raise_error(ArgumentError)
    expect { described_class.new(id: "q1") }.to raise_error(ArgumentError)
  end
end
