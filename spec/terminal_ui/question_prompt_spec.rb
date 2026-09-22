# frozen_string_literal: true

require "samagotchi/terminal_ui/question_prompt"

RSpec.describe Samagotchi::TerminalUI::QuestionPrompt do
  let(:pending) { { "id" => "q1", "question" => "Which one?", "options" => ["Apple", " Banana ", "", "Cherry"] } }
  let(:prompt) { described_class.new(pending) }

  it "reads a pending question with string or symbol keys" do
    expect(prompt.id).to eq("q1")
    expect(prompt.options).to eq(%w[Apple Banana Cherry])
    expect(described_class.new(id: "q2", question: "Q", options: %w[a b]).options).to eq(%w[a b])
  end

  it "lists the question and numbered options" do
    expect(prompt.lines).to eq(["? Which one?", "  1) Apple", "  2) Banana", "  3) Cherry"])
    expect(described_class.new(pending.merge("header" => "Fruit", "multi_select" => true)).lines(color: true).values_at(0, -1))
      .to eq(["Fruit", "  [Select one or more (e.g. 1,3)]"])
  end

  {
    "2" => { selected: ["Banana"], freeform: nil },
    "banana" => { selected: ["Banana"], freeform: nil },
    "che" => { selected: ["Cherry"], freeform: nil },
    "1; soft ones" => { selected: ["Apple"], freeform: "soft ones", note: "(note: freeform not flagged but accepting 'soft ones')" },
    "; just text" => { selected: [], freeform: "just text", note: "(note: freeform not flagged but accepting 'just text')" },
    "9" => { error: "Invalid choice '9': pick 1-3" },
    "kiwi" => { error: "Unknown option 'kiwi'. Use numbers 1-3 or exact labels." },
    "1,2" => { error: "This is single-select (pick one). Try again." },
    "1,1" => { selected: ["Apple"], freeform: nil },
    ";" => { error: "No selection. Try again." }
  }.each do |raw, expected|
    it "parses #{raw.inspect}" do
      answer = prompt.parse(raw)

      expect(answer.to_h.compact).to eq(expected.compact)
    end
  end

  it "takes several picks in a multi-select, and freeform text without a note when allowed" do
    multi = described_class.new(pending.merge("multi_select" => true, "allow_freeform" => true))

    expect(multi.parse("1 3; ripe").to_h.compact).to eq(selected: %w[Apple Cherry], freeform: "ripe")
  end
end
