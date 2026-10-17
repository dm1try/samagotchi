# frozen_string_literal: true

require "json"
require "samagotchi/pending_question"

# The pending question as a value (QuestionDesk, Session#pending_question)
# and its Hash shapes at the boundary.
RSpec.describe Samagotchi::PendingQuestion do
  let(:saved_shapes) { JSON.parse(File.read(File.expand_path("fixtures/pending_question/saved_shapes.json", __dir__))) }

  it "reads each saved kind and writes it back the same: string keys, unset fields left out" do
    saved_shapes.each do |kind, record|
      question = described_class.from_file(record)
      expect(question.to_file).to eq(record), kind
    end
    expect(described_class.from_file(saved_shapes["question"]).to_file.to_a).to eq(saved_shapes["question"].to_a)
    expect(described_class.from_file(saved_shapes["approval"]).to_file.to_a).to eq(saved_shapes["approval"].to_a)
  end

  it "gives its fields by name, nested Hashes as they were saved" do
    question = described_class.from_file(saved_shapes["approval"])
    expect(question).to have_attributes(id: "8f2e9b30-2d70-4c79-9c2e-3b4f5a6b7c83", kind: "approval",
                                        options: ["Allow once", "Allow for this session", "Deny"],
                                        multi_select: false, status: "pending", hook: nil, limit: nil)
    expect(question.approval).to include("tool" => "execute", "scopes" => %w[once session])
    expect(question.relayed_to).to include("relay_id" => "r-1")
  end

  it "has symbol keys in #to_h, in member order, unset fields and nil left out, false kept" do
    question = described_class.new(id: "q1", question: "Which?", options: %w[A B], multi_select: false,
                                   status: "pending", created_at: "t")
    expect(question.to_h.to_a).to eq([[:id, "q1"], [:question, "Which?"], [:options, %w[A B]], [:multi_select, false],
                                      [:status, "pending"], [:created_at, "t"]])
    expect(question.with(relayed_to: { relay_id: "r" }).to_h.keys.last).to eq(:relayed_to)
  end

  it "reads symbol keys, keeps a PendingQuestion as it is, is nil for anything but a Hash, drops an unknown key" do
    question = described_class.from_file({ id: "q1", kind: "hook", from_the_future: 1 })
    expect(question).to eq(described_class.new(id: "q1", kind: "hook"))
    expect(described_class.from_file(question)).to be(question)
    expect(described_class.from_file(nil)).to be_nil
    expect(described_class.from_file("q1")).to be_nil
  end

  it "refuses a field it doesn't know when built in the process" do
    expect { described_class.new(id: "q1", colour: "red") }.to raise_error(ArgumentError)
  end
end
