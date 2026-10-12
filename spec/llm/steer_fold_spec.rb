# frozen_string_literal: true

require "samagotchi/llm/steer_fold"

RSpec.describe Samagotchi::LLM::SteerFold do
  def call(id) = { role: "model", content: "", tool_calls: [{ id: id, name: "read", arguments: {} }] }
  def result(id) = { role: "tool_response", content: "[read]\n#{id}", tool_call_id: id }
  def steer(text = "nudge", source: "check-in") = { role: "user", kind: "steer", source: source, content: text }

  let(:prompt) { { role: "user", content: "go" } }

  def plan(conversation, paired: %w[c1 c2 c3]) = described_class.plan(conversation, paired: paired)

  describe ".foldable?" do
    it "is a plugin's steer with text content" do
      expect(described_class.foldable?(steer)).to be(true)
      expect(described_class.foldable?(steer(source: "agents-md").transform_keys(&:to_s))).to be(true)
    end

    it "is not a person's steer, a hook's with no label, input lines, or a steer with parts" do
      %w[user parent_agent chi_send].push("").each do |source|
        expect(described_class.foldable?(steer(source: source))).to be(false), source.inspect
      end
      expect(described_class.foldable?({ role: "user", kind: "input", source: "plugin_send", content: "x" })).to be(false)
      expect(described_class.foldable?({ role: "user", content: "go" })).to be(false)
      expect(described_class.foldable?(steer.merge(content: [{ type: "text", text: "x" }]))).to be(false)
    end
  end

  describe ".plan" do
    it "folds a plugin steer into the paired tool result right before it" do
      expect(plan([prompt, call("c1"), result("c1"), steer])).to eq(3 => 2)
    end

    it "chains the steers of one drain into one target, in order" do
      expect(plan([prompt, call("c1"), result("c1"), steer("a"), steer("b", source: "agents-md")])).to eq(3 => 2, 4 => 2)
    end

    it "folds into the last tool result of a parallel batch" do
      conversation = [prompt, { role: "model", content: "", tool_calls: [{ id: "c1" }, { id: "c2" }] },
                      result("c1"), result("c2"), steer]

      expect(plan(conversation)).to eq(4 => 3)
    end

    it "leaves a steer after a user line, a system note, a model reply, at the start, or after an unpaired result" do
      expect(plan([steer])).to eq({})
      expect(plan([prompt, steer])).to eq({})
      expect(plan([prompt, call("c1"), result("c1"), { role: "user", kind: "input", content: "line" }, steer])).to eq({})
      expect(plan([prompt, call("c1"), result("c1"), { role: "system", content: "[note]" }, steer])).to eq({})
      expect(plan([prompt, { role: "model", content: "ok" }, steer])).to eq({})
      expect(plan([prompt, call("c1"), result("c1"), steer], paired: [])).to eq({})
    end

    it "leaves a person's steer, and a plugin steer that follows one" do
      conversation = [prompt, call("c1"), result("c1"), steer("go on", source: "user"), steer]

      expect(plan(conversation)).to eq({})
    end

    it "is stable: the plan for every prefix agrees with the plan for the whole" do
      conversation = [prompt, call("c1"), result("c1"), steer("a"), steer("b"), call("c2"), result("c2"),
                      { role: "user", kind: "input", content: "line" }, steer("c"), call("c3"), result("c3"), steer("d")]
      whole = plan(conversation)

      expect(whole).to eq(3 => 2, 4 => 2, 11 => 10)
      (1..conversation.length).each do |length|
        expect(plan(conversation.first(length))).to eq(whole.select { |index, _| index < length })
      end
    end
  end
end
