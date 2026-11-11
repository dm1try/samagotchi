# frozen_string_literal: true

require "spec_helper"
require "samagotchi/objectives_record"
require "samagotchi/session_chain"

# Moved from spec/objectives_check_spec.rb with the record itself (Check this's
# and the tracker's): the expectations are as they were.
RSpec.describe Samagotchi::ObjectivesRecord do
  def move(id = "O1", note: "ran the suite", evidence: "0 failures", ref: "t1", at: "2026-11-04T09:00:00.000+01:00")
    [chat_model(chat_call("c1", "objectives", id: id, note: note, evidence: evidence)).merge(Samagotchi::MessageTime::KEY => at),
     chat_result("c1", "objectives", "Recorded a move on #{id}. The list is unchanged").merge(tool_ids: [ref])]
  end

  def chat_model(*calls, content: "") = { role: "model", content: content, tool_calls: calls }

  def chat_call(id, name, **arguments) = { id: id, name: name, arguments: arguments }

  def chat_result(id, name, text)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [id] }
  end

  describe ".record" do
    it "keeps the newest of a long record, each run's output cut" do
      conversation = (1..200).flat_map do |n|
        [chat_model(chat_call("c#{n}", "execute", command: "step #{n}")), chat_result("c#{n}", "execute", "x" * 5000)]
      end

      text = described_class.record(conversation)

      expect(text.length).to be <= described_class::RECORD_CHARS + 100
      expect(text).to include("step 200").and include("[earlier record left out]")
      expect(text).not_to include("step 1 ")
      expect(text).not_to match(/x{#{described_class::OUTPUT_CHARS + 1}}/)
    end

    it "leaves the objectives tool's own calls out: a move isn't evidence for itself" do
      text = described_class.record(move("O1", note: "SELF NOTE"))

      expect(text).not_to include("SELF NOTE")
    end

    it "leaves a continue's carry note out: the last answer in it is the agent's prose" do
      carry = Samagotchi::ContextNote.message(note_id: "c", text: "AGENT LAST ANSWER", source: Samagotchi::SessionChain::NOTE_SOURCE)

      expect(described_class.record([carry])).not_to include("AGENT LAST ANSWER")
    end

    it "keeps each answer's words whole enough, cut as any entry is" do
      text = described_class.record([{ role: "model", content: "#{"a" * 5000}the question?" }])

      expect(text).to start_with("[agent's own words]\n").and include("the question?")
      expect(text).not_to match(/a{#{described_class::OUTPUT_CHARS + 1}}/)
    end

    it "a tool-call-only step adds no empty label, in either storage" do
      chat = chat_model(chat_call("c", "execute", command: "ls"))
      qwen = { role: "model", content: "<think>\nhm\n</think>\n\n<tool_call>\n<function=execute>\n</function>\n</tool_call>" }
      gemma = { role: "model", content: "<|tool_call>call:execute{command:<|\"|>ls<|\"|>}<tool_call|>" }

      expect(described_class.record([chat, qwen, gemma])).to eq("")
    end

    it "keeps thinking out: the chat loop's fields and every inline form of the native loop's" do
      fields = { role: "model", content: "VISIBLE 0", thinking: "SECRET THOUGHT", reasoning_content: "SECRET THOUGHT",
                 "anthropic_content" => [{ "type" => "thinking", "thinking" => "SECRET THOUGHT" }] }
      inline = [
        "<think>\nSECRET THOUGHT\n</think>\n\nVISIBLE 1",
        "SECRET THOUGHT\n</think>\nVISIBLE 2",
        "<|channel>thought\nSECRET THOUGHT<channel|>VISIBLE 3",
        "<|think|>SECRET THOUGHT<|channel>thought\nx<channel|>VISIBLE 4",
        "<think>\nSECRET THOUGHT cut off by the limit",
        "<|channel>thought\nSECRET THOUGHT cut off by the limit"
      ].map { |content| { role: "model", content: content } }

      text = described_class.record([fields, *inline])

      expect(text).not_to include("SECRET THOUGHT", "<think>", "<|channel>", "<channel|>")
      expect(text).to include("VISIBLE 0", "VISIBLE 1", "VISIBLE 2", "VISIBLE 3", "VISIBLE 4")
      expect(text.scan("[agent's own words]").size).to eq(5)
    end

    it "a native step keeps its words and loses its calls, the objectives tool's too" do
      entry = { role: "model", content: <<~CONTENT }
        Two questions for you?
        <tool_call>
        <function=objectives>
        <parameter=note>SELF NOTE</parameter>
        </function>
        </tool_call>
      CONTENT

      text = described_class.record([entry])

      expect(text).to eq("[agent's own words]\nTwo questions for you?")
    end

    it "keeps the text of a multipart user entry" do
      entry = { role: "user", content: [{ type: "text", text: "look at this" }, { type: "image_url", image_url: { url: "x" } }], turn_id: "t" }

      expect(described_class.record([entry])).to include("look at this")
      expect(described_class.record([entry])).not_to include("image_url")
    end
  end

  it "frames a body on its tag and cuts a long text around an ellipsis" do
    tag = described_class.tag

    expect(tag).to match(/\Arecord-[0-9a-f]{16}\z/)
    expect(described_class.framed(tag, "inside")).to eq("<#{tag}>\ninside\n</#{tag}>")
    expect(described_class.cut("a" * 10, 4)).to eq("aa\n…\naa")
  end
end
