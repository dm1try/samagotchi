# frozen_string_literal: true

require "samagotchi/tools/ask_user_question"

RSpec.describe Samagotchi::Tools::AskUserQuestion do
  describe ".normalize_options_lenient" do
    it "strips <|...|> control tokens wrapped around options" do
      expect(described_class.normalize_options_lenient(["<|tool_call|>Rust", "Zig<|", "|>Go"])).to eq(%w[Rust Zig Go])
    end

    it "strips stray <| and |> fragments from option labels" do
      expect(described_class.normalize_options_lenient(["|>Rust<|", "|>Zig<|", "|>Elixir<|"])).to eq(%w[Rust Zig Elixir])
    end

    it "keeps normal labels untouched" do
      expect(described_class.normalize_options_lenient(["Rust", "Zig"])).to eq(%w[Rust Zig])
    end

    it "returns an empty array for nil" do
      expect(described_class.normalize_options_lenient(nil)).to eq([])
    end

    it "parses a JSON string array" do
      expect(described_class.normalize_options_lenient('["Cats","Dogs"]')).to eq(%w[Cats Dogs])
    end
  end

  describe ".sanitize_option" do
    it "strips control tokens" do
      expect(described_class.sanitize_option("<|tool_call|>Ruby<|")).to eq("Ruby")
    end

    it "returns nil when only control tokens remain" do
      expect(described_class.sanitize_option("<||>")).to be_nil
    end
  end
end
