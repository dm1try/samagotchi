# frozen_string_literal: true
require "samagotchi/tool_call_parser"
require "samagotchi/model_profile"
RSpec.describe Samagotchi::ToolCallParser do
  describe "gemma4: current_model_only in memory_write" do
    let(:profile) { Samagotchi::ModelProfile.normalize(:gemma4) }
    let(:parser) { described_class::Gemma.new(profile) }
    it "extracts current_model_only: true from gemma wire format" do
      text = "<|tool_call>call:memory_write{content:\"overlay\", name: \"test_entry\", scope: \"system\", current_model_only:true}<tool_call|>"
      calls = parser.parse(text)
      expect(calls).to have_attributes(size: 1)
      expect(calls.first[:name]).to eq("memory_write")
      expect(calls.first[:path]).to eq("test_entry")
      expect(calls.first[:scope]).to eq("system")
      expect(calls.first[:current_model_only]).to eq("true")
    end
    it "extracts current_model_only: false from gemma wire format" do
      text = "<|tool_call>call:memory_write{content:\"base\", name: \"test_entry\", scope: \"system\", current_model_only:false}<tool_call|>"
      calls = parser.parse(text)
      expect(calls.first[:current_model_only]).to eq("false")
    end
  end

  describe "send_note and list_sessions" do
    it "parses them in the Gemma format" do
      parser = described_class::Gemma.new(Samagotchi::ModelProfile.normalize(:gemma4))

      note = parser.parse("<|tool_call>call:send_note{session:<|\"|>3f2a1c<|\"|>,text:<|\"|>the API moved<|\"|>}<tool_call|>").first
      list = parser.parse("<|tool_call>call:list_sessions{cwd:<|\"|>/work/foo<|\"|>}<tool_call|>").first

      expect(note).to include(name: "send_note", content: "the API moved", session: "3f2a1c")
      expect(list).to include(name: "list_sessions", cwd: "/work/foo")
    end

    it "parses them in the Qwen format" do
      parser = described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36))

      note = parser.parse("<tool_call>\n<function=send_note>\n<parameter=session>\n3f2a1c\n</parameter>\n" \
                          "<parameter=text>\nthe API moved\n</parameter>\n</function>\n</tool_call>").first
      list = parser.parse("<tool_call>\n<function=list_sessions>\n</function>\n</tool_call>").first

      expect(note).to include(name: "send_note", content: "the API moved", session: "3f2a1c")
      expect(list).to include(name: "list_sessions")
      expect(list[:cwd].to_s).to eq("")
    end
  end

  describe "Qwen#strip_thought" do
    let(:parser) { described_class::Qwen.new(Samagotchi::ModelProfile.normalize(:qwen36)) }

    # A chat host's answer has no think block at all, and it is saved as
    # stripped: collapsing every blank line merged its markdown paragraphs
    # and lists for good.
    it "keeps the blank lines of an answer with no think block" do
      answer = "All checks passed:\n\n- a\n- b\n\nAll **good**.\n\n\nSecond paragraph."
      expect(parser.strip_thought(answer)).to eq(answer)
    end

    it "drops a block with the blank lines after it and keeps the answer's own" do
      expect(parser.strip_thought("<think>\nplan\n</think>\n\nOne.\n\nTwo.")).to eq("One.\n\nTwo.")
      expect(parser.strip_thought("</think>\n\nOne.\n\nTwo.")).to eq("One.\n\nTwo.")
    end
  end
end
