# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/push/attention"

# The server's port of notify.js's rules (attentionFor, closedKeys,
# attentionText), P1's part: approvals and questions.
RSpec.describe Samagotchi::Web::Push::Attention do
  def s(question = nil, **kw) = { id: "s1", pending_question: question }.merge(kw).compact

  describe ".for" do
    it "is a new question's reason and key, filtered on the reason (a hook's is a question)" do
      expect(described_class.for(nil, s({ id: "q", kind: "approval" })))
        .to eq(described_class::Event.new(reason: "approval", session_id: "s1", key: "s1:q", hold: nil))
      expect(described_class.for(s, s({ id: "q", kind: "hook" })).reason).to eq("question")
      expect(described_class.for(s, s({ id: "q", kind: "question" })).reason).to eq("question")
      expect(described_class.for(s, s({ id: "q", kind: "continue" }))).to be_nil
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

  describe ".text" do
    it "is the session's name clipped to 61 and the reason's words, never the question" do
      expect(described_class.text({ title: "fix it", first_preview: "x" }, "approval")).to eq(["fix it", "needs approval"])
      expect(described_class.text({ title: "  ", first_preview: "the first" }, "question")).to eq(["the first", "needs an answer"])
      expect(described_class.text({}, "question").first).to eq("chi session")
      long = described_class.text({ title: "a" * 80 }, "approval").first
      expect(long).to eq("#{"a" * 60}…")
    end
  end
end
