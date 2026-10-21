# frozen_string_literal: true

require "spec_helper"
require "digest"
require "samagotchi/llm/anthropic_wire"

RSpec.describe Samagotchi::LLM::AnthropicWire do
  # The one rule the adapter (binding recovery) and ChatLoop (the settle)
  # share for naming a replayed thinking block.
  describe ".thinking_block?" do
    it "is true for thinking and redacted_thinking blocks, string or symbol keys" do
      expect(described_class.thinking_block?({ "type" => "thinking" })).to be(true)
      expect(described_class.thinking_block?({ type: "redacted_thinking" })).to be(true)
    end

    it "is false for any other block and for what is no Hash" do
      expect(described_class.thinking_block?({ "type" => "text" })).to be(false)
      expect(described_class.thinking_block?({})).to be(false)
      expect(described_class.thinking_block?(nil)).to be(false)
      expect(described_class.thinking_block?("thinking")).to be(false)
    end
  end

  describe ".tools" do
    let(:function) { { name: "read", description: "Read.", parameters: { type: "object", properties: {} } } }

    it "keeps a deferred definition's defer_loading, and adds none to the others" do
      tools = described_class.tools([{ type: "function", function: function },
                                     { type: "function", function: function.merge(name: "web_fetch"), defer_loading: true }])

      expect(tools).to eq([{ name: "read", description: "Read.", input_schema: { type: "object", properties: {} } },
                           { name: "web_fetch", description: "Read.", input_schema: { type: "object", properties: {} },
                             defer_loading: true }])
    end
  end

  describe ".block_identity" do
    it "is a thinking block's signature, string or symbol keys" do
      expect(described_class.block_identity({ "type" => "thinking", "thinking" => "t", "signature" => "sig1" })).to eq("sig1")
      expect(described_class.block_identity({ type: "thinking", thinking: "t", signature: "sig1" })).to eq("sig1")
    end

    it "is a redacted_thinking block's data" do
      expect(described_class.block_identity({ "type" => "redacted_thinking", "data" => "opaque" })).to eq("opaque")
      expect(described_class.block_identity({ type: "redacted_thinking", data: "opaque" })).to eq("opaque")
    end

    it "is a digest of the thinking text when the signature is empty (Splash) or missing" do
      digest = "text:#{Digest::SHA256.hexdigest("hm")}"

      expect(described_class.block_identity({ "type" => "thinking", "thinking" => "hm", "signature" => "" })).to eq(digest)
      expect(described_class.block_identity({ type: "thinking", thinking: "hm" })).to eq(digest)
    end

    it "is nil for a block with neither, and for any other block" do
      expect(described_class.block_identity({ "type" => "thinking", "thinking" => "", "signature" => "" })).to be_nil
      expect(described_class.block_identity({ "type" => "redacted_thinking", "data" => "" })).to be_nil
      expect(described_class.block_identity({ "type" => "text", "text" => "hi" })).to be_nil
      expect(described_class.block_identity("thinking")).to be_nil
    end
  end
end
