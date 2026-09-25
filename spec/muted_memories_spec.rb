# frozen_string_literal: true

require "samagotchi/muted_memories"

RSpec.describe Samagotchi::MutedMemories do
  describe ".normalize" do
    it "strips a scope prefix and a .md suffix" do
      expect(described_class.normalize("project/gh-helper")).to eq("gh-helper")
      expect(described_class.normalize("gh-helper.md")).to eq("gh-helper")
      expect(described_class.normalize(" cli_usage ")).to eq("cli_usage")
      expect(described_class.normalize("")).to be_nil
    end

    it "keeps a slash that is not a scope" do
      expect(described_class.normalize("dir/thing")).to eq("thing")
    end
  end

  describe ".normalize_list" do
    it "splits comma lists, normalizes and dedupes" do
      expect(described_class.normalize_list(["a, system/b", "b.md", "", nil])).to eq(%w[a b])
    end
  end

  describe ".filter_index" do
    let(:index) do
      <<~MD
        # Memory Index

        Managed entries below are auto-maintained.
        - **gh-helper** · system · 2026-09-01 · 120 — GitHub helper
        - **cli_usage** · system · 2026-09-01 · 80 — CLI
        - **legacy**: old shape
        - **old.md** · system · 2026-09-01 · 10

        ## Notes
        gh-helper is mentioned here in prose.
      MD
    end

    it "drops only the lines naming a muted memory, byte-for-byte otherwise" do
      out = described_class.filter_index(index, %w[gh-helper legacy old])
      expect(out).to eq(<<~MD)
        # Memory Index

        Managed entries below are auto-maintained.
        - **cli_usage** · system · 2026-09-01 · 80 — CLI

        ## Notes
        gh-helper is mentioned here in prose.
      MD
    end

    it "returns the text untouched with no mutes" do
      expect(described_class.filter_index(index, [])).to equal(index)
    end

    it "drops a bare name from the no-index fallback listing" do
      text = "Stored memories (no index yet):\ngh-helper\ncli_usage\n"
      expect(described_class.filter_index(text, %w[gh-helper])).to eq("Stored memories (no index yet):\ncli_usage\n")
    end
  end
end
