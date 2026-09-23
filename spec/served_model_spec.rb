# frozen_string_literal: true

require "samagotchi/served_model"
require "samagotchi/client"

RSpec.describe Samagotchi::ServedModel do
  describe ".differs?" do
    it "is false for the same name, any case, or a name the other one extends" do
      expect(described_class.differs?("unsloth/Qwen3.6", "unsloth/qwen3.6")).to be(false)
      expect(described_class.differs?("z-ai/glm-5.2:free", "z-ai/glm-5.2")).to be(false)
      expect(described_class.differs?("openai/gpt-4o", "openai/gpt-4o-2024-08-06")).to be(false)
    end

    it "is true for another model or another quant, and false when either is unknown" do
      expect(described_class.differs?("unsloth/Qwen3.6-35B-A3B-GGUF:Q4_K_M", "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M")).to be(true)
      expect(described_class.differs?("x/m-GGUF:Q4_K_M", "x/m-GGUF:Q4_K_XL")).to be(true)
      expect(described_class.differs?(nil, "a")).to be(false)
      expect(described_class.differs?("a", "")).to be(false)
    end
  end

  describe ".from_props" do
    it "reads llama.cpp's model_alias from an answered probe only" do
      answered = Samagotchi::Client::ServerProps.new(body: { "model_alias" => "ornith" }, status: :ok)

      expect(described_class.from_props(answered)).to eq("ornith")
      expect(described_class.from_props(Samagotchi::Client::ServerProps.new(body: nil, status: :http_error))).to be_nil
      expect(described_class.from_props(Samagotchi::Client::ServerProps.new(body: { "model_alias" => " " }, status: :ok))).to be_nil
      expect(described_class.from_props(nil)).to be_nil
    end
  end
end
