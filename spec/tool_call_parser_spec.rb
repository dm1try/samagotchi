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
end
