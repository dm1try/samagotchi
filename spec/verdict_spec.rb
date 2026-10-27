# frozen_string_literal: true

require "samagotchi/verdict"

RSpec.describe Samagotchi::Verdict do
  describe ".parse" do
    it "parses the last non-empty line, stripping bold and backtick markup" do
      parsed = described_class.parse("First line\n\n**Verdict:** `CONFIRMED` — **the source supports it**\n\n")

      expect(parsed).to eq(described_class.new(verdict: "confirmed", reason: "the source supports it"))
    end

    it "accepts hyphen and en dash separators" do
      expect(described_class.parse("Verdict: refuted - not in the source").verdict).to eq("refuted")
      expect(described_class.parse("Verdict: unclear – insufficient context").verdict).to eq("unclear")
    end

    it "does not accept an earlier verdict line when the final non-empty line is not a verdict" do
      expect(described_class.parse("Verdict: confirmed — supported\nConclusion: done")).to be_nil
    end

    it "rejects a missing, empty, or malformed verdict" do
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse("Verdict: confirmed — ")).to be_nil
      expect(described_class.parse("Verdict: probably — maybe")).to be_nil
    end
  end
end
