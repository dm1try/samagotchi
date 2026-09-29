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

RSpec.describe Samagotchi::TerminalUI::QuestionPrompt, "approval" do
  let(:prompt) do
    described_class.new(id: "a", kind: "approval", question: "execute: rm -rf x",
                        options: ["Allow once", "Allow this call in this repo", "Deny"], allow_freeform: true)
  end

  def pick(raw) = prompt.parse(raw)

  it "takes y/n, numbers and exact labels (any case)" do
    expect(pick("y").selected).to eq(["Allow once"])
    expect(pick("YES").selected).to eq(["Allow once"])
    expect(pick("n").selected).to eq(["Deny"])
    expect(pick("2").selected).to eq(["Allow this call in this repo"])
    expect(pick("allow this call in this repo").selected).to eq(["Allow this call in this repo"])
    expect(pick("deny").selected).to eq(["Deny"])
  end

  it "rejects substrings and numbers out of range" do
    expect(pick("allow")).not_to be_ok
    expect(pick("en")).not_to be_ok
    expect(pick("4")).not_to be_ok
    expect(pick("0").error).to eq("Answer with 1-3, y (Allow once) or n (Deny).")
  end

  it "keeps a reason after ';', also with no pick (a deny with that reason)" do
    expect(pick("n; not now").to_h).to include(selected: ["Deny"], freeform: "not now")
    expect(pick("; use a branch").to_h).to include(selected: [], freeform: "use a branch")
  end

  describe "#preview_lines (an edit approval's diff, printed above the slot)" do
    def prompt_with(preview) = described_class.new({ "id" => "a1", "kind" => "approval", "question" => "edit: /k.conf",
                                                     "options" => %w[Allow Deny], "approval" => { "preview" => preview } })

    let(:diff) { { "text" => "@@ -1,2 +1,2 @@\n a\n-b\n+c\n\\ No newline at end of file", "added" => 1, "removed" => 1 } }

    it "reads string-keyed nested input (a reload, SSE) and colours + / - / @@" do
      paint = ->(text, code) { code.zero? ? text : "<#{code}>#{text}" }
      expect(prompt_with(diff).preview_lines(paint: paint))
        .to eq(["<2>@@ -1,2 +1,2 @@", " a", "<31>-b", "<32>+c", "<2>\\ No newline at end of file"])
      expect(described_class.new(id: "a", question: "q", options: %w[a], approval: { preview: diff.transform_keys(&:to_sym) })
        .preview_lines).to eq(["@@ -1,2 +1,2 @@", " a", "-b", "+c", "\\ No newline at end of file"])
    end

    it "cuts at 40 lines and counts what TextDiff already cut" do
      lines = ["@@ -0,0 +1,300 @@"] + Array.new(119) { |i| "+#{i}" } + ["… 181 more lines"]
      out = prompt_with("text" => lines.join("\n"), "added" => 300, "new_file" => true).preview_lines
      expect(out.first).to eq("new file")
      expect(out.size).to eq(42)
      expect(out.last).to eq("… 261 more lines (full diff on the web)")
    end

    it "says why there's no diff, and gives nothing without a preview" do
      expect(prompt_with("error" => "old text not found in /k").preview_lines).to eq(["this edit would fail: old text not found in /k"])
      expect(prompt_with("skipped" => "binary file").preview_lines).to eq(["diff not shown: binary file"])
      expect(prompt.preview_lines).to eq([])
    end
  end
end
