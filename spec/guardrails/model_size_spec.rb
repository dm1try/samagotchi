# frozen_string_literal: true

require "samagotchi/guardrails"
require "samagotchi/model_overlay"

RSpec.describe Samagotchi::Guardrails::ModelSize do
  def key(name) = Samagotchi::ModelOverlay.key_for(name)

  describe ".billions" do
    {
      "Qwen3.6-27B" => 27,
      "Ornith-1.5-35B-A3B" => 3,
      "Qwen3-235B-A22B" => 22,
      "incoai/Qwen3.8-27B-Splash" => 27,
      "gemma-4-E4B-it" => 4,
      "Qwen2.5-1.5B" => 1.5,
      "Qwen3-8B-4bit" => 8,
      "Mixtral-8x7B" => 56,
      "llama3:70b" => 70,
      "qwen3_14b_q4" => 14,
      "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M" => 3,
      "unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M" => 3,
      "ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF:MTP" => 27,
      "deepseek-v4.1-flash" => nil,
      "gpt-5" => nil,
      "" => nil
    }.each do |name, size|
      it "reads #{size.inspect} from #{name.inspect}" do
        expect(described_class.billions(name)).to eq(size)
      end
    end
  end

  describe ".small? with auto" do
    it "is small at 32B or less, the active size counting for an MoE" do
      %w[Qwen3.6-27B Ornith-1.5-35B-A3B Qwen3-235B-A22B incoai/Qwen3.8-27B-Splash gemma-4-E4B-it Qwen2.5-1.5B
         Qwen3-8B-4bit Qwen3-32B].each do |name|
        expect(described_class.small?(name, key(name), "auto")).to be(true), name
      end
    end

    it "is not small above 32B, without a size in the name, or without a model" do
      %w[Mixtral-8x7B Llama-3.3-70B deepseek-v4.1-flash].each do |name|
        expect(described_class.small?(name, key(name), "auto")).to be(false), name
      end
      expect(described_class.small?(nil, nil, "auto")).to be(false)
    end

    it "treats a nil or blank-padded setting as auto" do
      expect(described_class.small?("Qwen3-8B", "qwen3-8b", nil)).to be(true)
      expect(described_class.small?("Qwen3-8B", "qwen3-8b", " AUTO ")).to be(true)
    end
  end

  describe ".small? with globs" do
    it "matches the bare name or the model key, case-insensitively" do
      expect(described_class.small?("Qwen3.6-27B", key("Qwen3.6-27B"), "Qwen3.6-*")).to be(true)
      expect(described_class.small?("Qwen3.6-27B", key("Qwen3.6-27B"), "qwen3-6-*")).to be(true)
      expect(described_class.small?("deepseek-v4.1-flash", key("deepseek-v4.1-flash"), "gemma*|deepseek-*")).to be(true)
      expect(described_class.small?("Qwen3-8B", key("Qwen3-8B"), "gemma*")).to be(false)
    end

    it "can list auto beside the globs" do
      expect(described_class.small?("deepseek-v4.1-flash", "deepseek-v4-1-flash", "auto|deepseek-*")).to be(true)
      expect(described_class.small?("Qwen3-8B", "qwen3-8b", "auto|deepseek-*")).to be(true)
      expect(described_class.small?("Llama-3.3-70B", "llama-3-3-70b", "auto|deepseek-*")).to be(false)
    end

    it "is never small with an empty setting ([] in config.yml)" do
      expect(described_class.small?("Qwen3-8B", "qwen3-8b", "")).to be(false)
    end
  end

  describe ".describe" do
    it "says small or not, and why" do
      expect(described_class.describe("Qwen3.6-27B", "qwen3-6-27b", "auto")).to eq("small (auto, 27B)")
      expect(described_class.describe("Ornith-1.5-35B-A3B", "ornith-1-5-35b-a3b", "auto")).to eq("small (auto, 3B)")
      expect(described_class.describe("Llama-3.3-70B", "llama-3-3-70b", nil)).to eq("not small (auto, 70B)")
      expect(described_class.describe("deepseek-v4.1-flash", "deepseek-v4-1-flash", "auto")).to eq("not small (auto, no size in the name)")
      expect(described_class.describe("Qwen3-8B", "qwen3-8b", "")).to eq("not small (small_models: [])")
      expect(described_class.describe("Qwen3-8B", "qwen3-8b", "gemma*|qwen*")).to eq("small (small_models: gemma*|qwen*)")
      expect(described_class.describe(nil, nil, "auto")).to eq("not small (no model name)")
    end
  end

  describe ".setting" do
    it "reads guardrails.small_models live, auto by default, a YAML list joined with |" do
      entry = Samagotchi::Config.find_by_key("guardrails.small_models")
      expect([entry.type, entry.default]).to eq([:string, "auto"])
      expect(Samagotchi::Config.resolve("guardrails.small_models", file_data: { "guardrails" => { "small_models" => %w[a* b*] } }, env: {}))
        .to eq("a*|b*")
      expect(Samagotchi::Config.resolve("guardrails.small_models", file_data: { "guardrails" => { "small_models" => [] } }, env: {}))
        .to eq("")
      allow(Samagotchi::Config).to receive(:get).with("guardrails.small_models").and_return("x*")
      expect(described_class.setting).to eq("x*")
    end
  end
end
