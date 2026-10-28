# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/push/attention"

# The server's port of notify.js's rules (attentionFor, closedKeys,
# attentionText). The cases both sides answer are in
# spec/fixtures/attention_cases.json (attention_cases_spec.rb); these are
# the Ruby side's own.
RSpec.describe Samagotchi::Web::Push::Attention do
  def s(question = nil, **kw) = { id: "s1", pending_question: question }.merge(kw).compact

  describe ".for" do
    it "is a new question's reason and key, filtered on the reason (a hook's is a question)" do
      expect(described_class.for(nil, s({ id: "q", kind: "approval" })))
        .to eq(described_class::Event.new(reason: "approval", session_id: "s1", key: "s1:q", hold: nil))
      expect(described_class.for(s, s({ id: "q", kind: "hook" })).reason).to eq("question")
      expect(described_class.for(s, s({ id: "q", kind: "question" })).reason).to eq("question")
      expect(described_class.for(s, s({ id: "q", kind: "continue" })).reason).to eq("continue")
    end

    it "is nothing for the same question, a relayed one or no question" do
      q = { id: "q", kind: "approval" }
      expect(described_class.for(s(q), s(q))).to be_nil
      expect(described_class.for(s, s(q.merge(relayed_to: "abcd1234")))).to be_nil
      expect(described_class.for(s(q), s)).to be_nil
    end

    it "holds a delegated child's approval or hook question, not its plain question" do
      expect(described_class.for(nil, s({ id: "q", kind: "approval" }, parent_id: "p")).hold).to eq(3.5)
      expect(described_class.for(nil, s({ id: "q", kind: "hook" }, parent_id: "p")).hold).to eq(3.5)
      expect(described_class.for(nil, s({ id: "q", kind: "question" }, parent_id: "p")).hold).to be_nil
    end
  end

  describe ".closed_keys" do
    let(:q) { { id: "q", kind: "approval" } }

    it "names a question answered, replaced, newly relayed or with its session gone" do
      expect(described_class.closed_keys(s(q), s)).to eq(["s1:q"])
      expect(described_class.closed_keys(s(q), s({ id: "q2", kind: "approval" }))).to eq(["s1:q"])
      expect(described_class.closed_keys(s(q), s(q.merge(relayed_to: "abcd1234")))).to eq(["s1:q"])
      expect(described_class.closed_keys(s(q), nil)).to eq(["s1:q"])
      expect(described_class.closed_keys(s(q), s(q))).to eq([])
      expect(described_class.closed_keys(nil, s)).to eq([])
    end
  end

  describe ".open_keys" do
    it "is every pending question (a hook's, a continue's too) and card, not a relayed one or no question" do
      by_id = {
        "a" => { id: "a", pending_question: { id: "q1", kind: "approval" } },
        "h" => { id: "h", pending_question: { id: "h1", kind: "hook" } },
        "r" => { id: "r", pending_question: { id: "q2", kind: "approval", relayed_to: "p1234567" } },
        "c" => { id: "c", pending_question: { id: "c1", kind: "continue" } },
        "k" => { id: "k", pending_card: { id: "k1", bundle: "check-in" } },
        "n" => { id: "n" },
        "x" => { id: "x", pending_question: { kind: "question" } }
      }
      expect(described_class.open_keys(by_id)).to eq(["a:q1", "h:h1", "c:c1", "k:card:k1"])
    end
  end

  describe ".waits?" do
    it "counts an identified, unrelayed question or card, but not a relayed or id-less one" do
      expect(described_class.waits?(pending_question: { id: "q" })).to be(true)
      expect(described_class.waits?(pending_question: { id: "q", relayed_to: "parent" })).to be(false)
      expect(described_class.waits?(pending_question: {})).to be(false)
      expect(described_class.waits?(pending_card: { id: "card" })).to be(true)
      expect(described_class.waits?(pending_card: {})).to be(false)
      expect(described_class.waits?({})).to be(false)
    end
  end

  describe ".text" do
    it "is the session's name clipped to 61 and the reason's words, never the question" do
      expect(described_class.text({ title: "fix it", first_preview: "x" }, "approval")).to eq(["fix it", "needs approval"])
      expect(described_class.text({ title: "  ", first_preview: "the first" }, "question")).to eq(["the first", "needs an answer"])
      expect(described_class.text({}, "question").first).to eq("chi session")
      expect(described_class.text({ title: "fix it", auto_title: "Login fix", first_preview: "x" }, "failed").first).to eq("fix it")
      expect(described_class.text({ title: nil, auto_title: "Login fix", first_preview: "x" }, "failed").first).to eq("Login fix")
      long = described_class.text({ title: "a" * 80 }, "approval").first
      expect(long).to eq("#{"a" * 60}…")
    end

    it "names the session as its card does: the recap's first sentence after the auto title, the first message without one" do
      summary = { auto_title: "Login fix", recap: "We fixed the login page.", first_preview: "x", last_prompt: "y" }
      expect(described_class.text(summary, "question").first).to eq("Login fix")
      expect(described_class.text(summary.merge(auto_title: nil), "question").first).to eq("We fixed the login page.")
      expect(described_class.text({ title: "fix it", recap: "We fixed the login page." }, "question").first).to eq("fix it")
      expect(described_class.text({ recap: "We fixed the login page.", last_prompt: "fix the login" }, "done").first)
        .to eq("We fixed the login page.")
      expect(described_class.text({ first_preview: "the first", last_prompt: "later" }, "question").first).to eq("the first")
    end

    it "says a failed turn and a done one with its seconds rounded, as attentionText" do
      expect(described_class.text({ title: "t" }, "failed")).to eq(["t", "turn failed"])
      expect(described_class.text({ title: "t", last_turn: { "seconds" => 12.5 } }, "done")).to eq(["t", "done in 13 s"])
      expect(described_class.text({ title: "t", last_turn: { "seconds" => "x" } }, "done")).to eq(["t", "done in 0 s"])
      expect(described_class.text({ title: "t" }, "done")).to eq(["t", "done in 0 s"])
      expect(described_class.text({ title: "t" }, "card")).to eq(["t", "needs you"])
    end

    it "names the verdict author and clips its reason for a push" do
      verdict = { verdict: "refuted", reason: "contradicted by the source", by: "p:reviewer", by_name: "Reviewer" }
      expect(described_class.text({ title: "claim", last_verdict: verdict }, "verdict"))
        .to eq(["claim", "Reviewer: ❌ refuted — contradicted by the source"])
      expect(described_class.text({ last_verdict: verdict.merge(reason: "x" * 140) }, "verdict").last)
        .to eq("Reviewer: ❌ refuted — #{"x" * 119}…")
      expect(described_class.text({ last_verdict: verdict.merge(by_name: nil) }, "verdict").last)
        .to eq("A participant: ❌ refuted — contradicted by the source")
      expect(described_class.text({ last_verdict: verdict.merge(by: nil, by_name: nil) }, "verdict").last)
        .to eq("You: ❌ refuted — contradicted by the source")
    end

    it "says You for an owner's verdict whose by is empty or the owner's mark" do
      ["", "owner"].each do |by|
        verdict = { verdict: "confirmed", reason: "matches", by: by }
        expect(described_class.text({ last_verdict: verdict }, "verdict").last).to eq("You: ✅ confirmed — matches")
      end
    end
  end
end
