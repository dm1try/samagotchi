# frozen_string_literal: true

require "samagotchi/model_profile"

RSpec.describe Samagotchi::ModelProfile do
  describe ".default" do
    it "returns the Gemma 4 profile by default" do
      profile = described_class.default
      expect(profile.name).to eq("gemma4")
      expect(profile.turn_start).to eq("<|turn>")
      expect(profile.turn_end).to eq("<end_of_turn>")
    end
  end

  describe ".gemma4" do
    it "returns Gemma 4 token configuration" do
      profile = described_class.gemma4
      expect(profile.name).to eq("gemma4")
      expect(profile.turn_start).to eq("<|turn>")
      expect(profile.turn_end).to eq("<end_of_turn>")
      expect(profile.tool_call_open).to eq("<|tool_call>")
      expect(profile.tool_call_close).to eq("<tool_call|>")
      expect(profile.tool_response_open).to eq("<|tool_response>")
      expect(profile.tool_response_close).to eq("<tool_response|>")
      expect(profile.stop_sequences).to eq(["<end_of_turn>", "<|tool_response>"])
    end

    it "uses channel-based thoughts" do
      profile = described_class.gemma4
      expect(profile.uses_channel_thoughts?).to be false
      expect(profile.uses_role_prefixes?).to be false
    end
  end

  describe ".qwen36" do
    it "returns Qwen 3.6 token configuration" do
      profile = described_class.qwen36
      expect(profile.name).to eq("qwen36")
      expect(profile.turn_start).to eq("")
      expect(profile.turn_end).to eq("")
      expect(profile.tool_call_open).to eq("<tool_call>")
      expect(profile.tool_call_close).to eq("</tool_call>")
      expect(profile.tool_response_open).to eq("<tool_response>")
      expect(profile.tool_response_close).to eq("</tool_response>")
      expect(profile.stop_sequences).to eq(["<|im_end|>"])
    end

    it "uses role prefixes and simple think tags" do
      profile = described_class.qwen36
      expect(profile.uses_role_prefixes?).to be true
      expect(profile.uses_channel_thoughts?).to be false
      expect(profile.thought_open).to eq("<think>")
      expect(profile.thought_close).to eq("</think>")
    end

    it "has correct role prefixes" do
      profile = described_class.qwen36
      expect(profile.system_prefix).to eq("<|im_start|>system\n")
      expect(profile.user_prefix).to eq("<|im_start|>user\n")
      expect(profile.assistant_prefix).to eq("<|im_start|>assistant\n")
    end
  end

  describe ".from_env" do
    after { ENV.delete("SAMAGOTCHI_MODEL_PROFILE") }

    it "returns Gemma 4 when SAMAGOTCHI_MODEL_PROFILE is not set" do
      ENV.delete("SAMAGOTCHI_MODEL_PROFILE")
      profile = described_class.from_env
      expect(profile.name).to eq("gemma4")
    end

    it "returns Qwen 3.6 when SAMAGOTCHI_MODEL_PROFILE=qwen36" do
      ENV["SAMAGOTCHI_MODEL_PROFILE"] = "qwen36"
      profile = described_class.from_env
      expect(profile.name).to eq("qwen36")
    end

    it "returns Gemma 4 when SAMAGOTCHI_MODEL_PROFILE=gemma4" do
      ENV["SAMAGOTCHI_MODEL_PROFILE"] = "gemma4"
      profile = described_class.from_env
      expect(profile.name).to eq("gemma4")
    end

    it "defaults to Gemma 4 for unknown profile names" do
      ENV["SAMAGOTCHI_MODEL_PROFILE"] = "unknown"
      profile = described_class.from_env
      expect(profile.name).to eq("gemma4")
    end
  end
end
