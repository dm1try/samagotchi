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

  describe ".validate" do
    it "returns the normalized payload for a good call" do
      call = { name: "ask_user_question", question: " Pets? ", options: '["Cats","Dogs"]',
               header: "<|x|>Pets", multi_select: "true", allow_freeform: "no" }
      expect(described_class.validate(call)).to eq(
        question: "Pets?", options: %w[Cats Dogs], header: "Pets", multi_select: true, allow_freeform: false
      )
    end

    it "drops an empty header and reads unknown booleans as false" do
      expect(described_class.validate(question: "Q", options: %w[A B], header: "  ", multi_select: "maybe"))
        .to eq(question: "Q", options: %w[A B], multi_select: false, allow_freeform: false)
    end

    it "falls back to the question text as the question (content)" do
      expect(described_class.validate(content: "Q?", options: %w[A B])).to include(question: "Q?")
    end

    it "keeps a single salvaged option" do
      expect(described_class.validate(question: "Q", options: ["Only"])).to include(options: ["Only"])
    end

    it "salvages options from content when options are missing" do
      expect(described_class.validate(question: "Q", content: '["A","B"]')).to include(options: %w[A B])
    end

    it "says the question is required, also when only wire tokens were given" do
      expect(described_class.validate(question: "", options: %w[A B])).to eq("Error: ask_user_question requires 'question'")
      expect(described_class.validate(question: "<|tool_call|>", options: %w[A B])).to eq("Error: ask_user_question requires 'question'")
    end

    it "gives the options-count error for none and for more than 8" do
      expect(described_class.validate(question: "Q", options: [])).to eq(described_class.options_count_error(0))
      nine = (1..9).map { |n| "O#{n}" }
      expect(described_class.validate(question: "Q", options: nine)).to eq(described_class.options_count_error(9))
    end
  end
end
