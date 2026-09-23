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

  describe ".from_model_name" do
    it "infers Qwen profile when model name contains qwen" do
      profile = described_class.from_model_name("Qwen3-14B-Instruct")
      expect(profile.name).to eq("qwen36")
    end

    it "infers Gemma profile when model name contains gemma" do
      expect(described_class.from_model_name("gemma-4-31B-it").name).to eq("gemma4")
    end

    # Many models with other names are Qwen-based (Ornith, ISTA-DASLab...).
    it "falls back to the Qwen profile for model names that say neither family" do
      expect(described_class.from_model_name("ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M").name).to eq("qwen36")
      expect(described_class.from_model_name("some-other-model").name).to eq("qwen36")
    end
  end

  describe ".required_model_name" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-empty") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        # Clear Config cache so file isolation takes effect
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        example.run
      ensure
        if original.nil?
          ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        else
          ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
        end
        ENV["XDG_CONFIG_HOME"] = original_xdg
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
      end
    end

    it "raises when model is missing" do
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      expect { described_class.required_model_name }
        .to raise_error(ArgumentError, /SAMAGOTCHI_DEFAULT_MODEL is required/)
    end

    it "returns explicit argument when provided" do
      ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      expect(described_class.required_model_name("Qwen3-14B-Instruct")).to eq("Qwen3-14B-Instruct")
    end

    it "returns environment model when argument is blank" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      expect(described_class.required_model_name(" ")).to eq("Gemma-4B-it")
    end
  end

  describe ".from_env" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      example.run
    ensure
      if original.nil?
        ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
      else
        ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
      end
    end

    it "infers qwen36 from SAMAGOTCHI_DEFAULT_MODEL" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3-14B-Instruct"
      profile = described_class.from_env
      expect(profile.name).to eq("qwen36")
    end

    it "infers gemma4 from a gemma SAMAGOTCHI_DEFAULT_MODEL" do
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      profile = described_class.from_env
      expect(profile.name).to eq("gemma4")
    end
  end
end
