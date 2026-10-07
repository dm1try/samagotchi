# frozen_string_literal: true

require "samagotchi/model_match"

RSpec.describe Samagotchi::ModelMatch do
  describe ".parse" do
    it "splits a string on |, strips the entries and drops blanks" do
      expect(described_class.parse(" deepseek-* | small ||*v4*")).to eq(%w[deepseek-* small *v4*])
    end

    it "takes a list, each entry split on | too, stripped" do
      expect(described_class.parse([" gemma-* ", "Qwen3-8B", ""])).to eq(%w[gemma-* Qwen3-8B])
      expect(described_class.parse(["gemma-*|qwen*", "small"])).to eq(%w[gemma-* qwen* small])
    end

    it "is empty for nil or blank" do
      expect(described_class.parse(nil)).to eq([])
      expect(described_class.parse("  ")).to eq([])
    end
  end

  describe ".match?" do
    let(:never_small) { -> { raise "small asked" } }

    def match(entries, name, key = nil, small: -> { false })
      described_class.match?(described_class.parse(entries), name: name, key: key, small: small)
    end

    it "matches a glob on the bare name or the key, ignoring case" do
      expect(match("deepseek/*", "deepseek/deepseek-v4.1-flash", "deepseek-deepseek-v4-1-flash")).to be(true)
      expect(match("*-v4-1-*", "deepseek/deepseek-v4.1-flash", "deepseek-deepseek-v4-1-flash")).to be(true)
      expect(match("QWEN3.6-*", "qwen3.6-27b")).to be(true)
      expect(match("gemma-*", "qwen3.6-27b", "qwen3-6-27b")).to be(false)
    end

    it "takes extglob braces" do
      expect(match("{gemma,qwen}*", "qwen3.6-27b")).to be(true)
    end

    it "wins on any entry" do
      expect(match("gemma-*|qwen*", "qwen3.6-27b")).to be(true)
    end

    it "asks small only for a small entry" do
      expect(match("small", "qwen3.6-27b", small: -> { true })).to be(true)
      expect(match("small", "qwen3.6-27b", small: -> { false })).to be(false)
      expect(match("qwen*", "qwen3.6-27b", small: never_small)).to be(true)
    end

    it "matches nothing without a model name" do
      expect(match("*", nil, small: -> { true })).to be(false)
      expect(match("small", "", small: -> { true })).to be(false)
    end
  end
end
