# frozen_string_literal: true

require "samagotchi/terminal_ui/question_prompt"

RSpec.describe Samagotchi::TerminalUI::QuestionSlot do
  # Reline asks the terminal how wide ambiguous characters are the first time
  # it measures one; never let a spec write that probe to a real terminal.
  before { allow(Reline).to receive(:ambiguous_width).and_return(1) }

  let(:approval) do
    Samagotchi::TerminalUI::QuestionPrompt.new(
      "id" => "a1", "kind" => "approval", "header" => "Approve tool call?",
      "question" => "execute: git push origin main\n  in /r (repo r, branch main)\n  why: pushes (rule git-push, config)",
      "options" => ["Allow once", "Allow this call for the session", "Allow this call in this repo",
                    "Allow rule git-push in this repo", "Deny"]
    )
  end
  let(:full) do
    ["Approve tool call?",
     "! execute: git push origin main",
     "  in /r (repo r, branch main)",
     "  why: pushes (rule git-push, config)",
     "  1) Allow once",
     "  2) Allow this call for the session",
     "  3) Allow this call in this repo",
     "  4) Allow rule git-push in this repo",
     "  5) Deny",
     "  [1-5, y = Allow once, n = Deny; add '; reason' to tell the model why; Enter alone denies]"]
  end

  it "shows everything when there is room (no height limit, or enough rows)" do
    expect(approval.slot.fit(width: 100, height: nil)).to eq(full)
    expect(approval.slot.fit(width: 100, height: 10)).to eq(full)
  end

  it "gives way on a short terminal: the hint, the details, the header, then the options fold" do
    slot = approval.slot
    expect(slot.fit(width: 100, height: 9)).to eq(full.first(9))
    expect(slot.fit(width: 100, height: 7)).to eq(full.values_at(0, 1, 4, 5, 6, 7, 8))
    expect(slot.fit(width: 100, height: 6)).to eq(full.values_at(1, 4, 5, 6, 7, 8))
    expect(slot.fit(width: 50, height: 5)).to eq(
      ["! execute: git push origin main",
       "  1) Allow once",
       "  2) Allow this call for the session",
       "  3) Allow this call in this repo",
       "  4) Allow rule git-push in this repo · 5) Deny"]
    )
    expect(slot.fit(width: 100, height: 3)).to eq(
      ["! execute: git push origin main",
       "  1) Allow once · 2) Allow this call for the session · 3) Allow this call in this repo",
       "  4) Allow rule git-push in this repo · 5) Deny"]
    )
  end

  it "keeps the question's first row and the options first when even folded they don't fit" do
    expect(approval.slot.fit(width: 40, height: 2).first).to eq("! execute: git push origin main")
    expect(approval.slot.fit(width: 40, height: 2).size).to eq(2)
  end

  it "wraps a long question while there is room, one row when short" do
    prompt = Samagotchi::TerminalUI::QuestionPrompt.new("id" => "q", "question" => "Which of these fruits do you like best?",
                                                        "options" => %w[Apple Pear])
    expect(prompt.slot.fit(width: 20, height: nil).first(3)).to eq(["? Which of these", "  fruits do you like", "  best?"])
    expect(prompt.slot.fit(width: 20, height: 3)).to eq(["? Which of these", "  1) Apple", "  2) Pear"])
  end

  it "keeps the mark with a word too long for a row, and cuts the word" do
    slot = described_class.new(question: "write: /Users/me/#{"y" * 30} now", mark: "! ", options: [])
    expect(slot.fit(width: 20, height: nil)).to eq(["! write:", "  /Users/me/yyyyyyyy", "  yyyyyyyyyyyyyyyyyy", "  yyyy now"])
  end

  it "paints each row" do
    rows = approval.slot(paint: ->(text, code) { "<#{code}>#{text}" }).fit(width: 100, height: nil)
    expect(rows.values_at(0, 1, 4, 9).map { |row| row[/\A<\d+>/] }).to eq(%w[<1> <33> <92> <90>])
  end

  describe "a continue offer" do
    it "says what yes and no do, with the model's last step while there is room" do
      slot = described_class.continue_offer({ last_model_intent: "run the specs\nagain" })
      expect(slot.fit(width: 80, height: nil)).to eq(
        ["? The turn ran out of iterations. Continue it?",
         "  last step: run the specs again",
         "  yes: continue (Enter alone too)",
         "  no: stop here",
         "  no, <reason>: stop and tell the model why"]
      )
      expect(slot.fit(width: 80, height: 3).first).to eq("? The turn ran out of iterations. Continue it?")
      expect(described_class.continue_summary("yes")).to eq("? The turn ran out of iterations. Continue it? → yes")
    end
  end
end

RSpec.describe Samagotchi::TerminalUI::QuestionPrompt, "summary line" do
  let(:question) { described_class.new("id" => "q1", "question" => "Which one?", "options" => %w[Apple Banana Cherry]) }
  let(:approval) do
    described_class.new("id" => "a1", "kind" => "approval", "question" => "execute: git push\n  in /r",
                        "options" => ["Allow once", "Deny"])
  end

  it "joins the question and its answer on one line" do
    expect(question.summary(question.answer_text(question.parse("2")))).to eq("? Which one? → Banana")
    multi = described_class.new("id" => "q", "question" => "Which?", "options" => %w[Apple Cherry], "multi_select" => true)
    expect(multi.answer_text(multi.parse("1 2; ripe ones"))).to eq("Apple, Cherry; ripe ones")
  end

  it "shows an approval by its tool line, with a reason after the choice" do
    expect(approval.summary(approval.answer_text(approval.parse("y")))).to eq("! execute: git push → Allow once")
    expect(approval.answer_text(approval.parse("n; use a PR"))).to eq("Deny: use a PR")
    expect(approval.answer_text(approval.parse("; use a PR"))).to eq("Deny: use a PR")
    expect(approval.summary("(denied)")).to eq("! execute: git push → (denied)")
  end
end
