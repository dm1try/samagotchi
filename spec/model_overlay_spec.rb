# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/samagotchi/model_overlay"

RSpec.describe Samagotchi::ModelOverlay do
  describe ".key_for" do
    it "normalizes dots" do
      expect(described_class.key_for("qwen3.6-35b-a3b")).to eq("qwen3-6-35b-a3b")
    end

    it "normalizes uppercase" do
      expect(described_class.key_for("Gemma4O")).to eq("gemma4o")
    end

    it "handles multiple/double separators" do
      expect(described_class.key_for("model__with___double")).to eq("model-with-double")
    end

    it "trims leading/trailing dashes" do
      expect(described_class.key_for("-gemma4-")).to eq("gemma4")
    end

    it "returns nil for empty input" do
      expect(described_class.key_for("")).to be_nil
      expect(described_class.key_for(nil)).to be_nil
    end

    it "returns nil for whitespace-only input" do
      expect(described_class.key_for("  ")).to be_nil
    end

    it "returns nil for input that normalizes to empty" do
      expect(described_class.key_for("---")).to be_nil
      expect(described_class.key_for("...")).to be_nil
      expect(described_class.key_for("__")).to be_nil
    end

    it "is idempotent (key→key produces same key)" do
      original = "qwen3-6-35b-a3b"
      expect(described_class.key_for(original)).to eq(original)
    end

    it "passes through alphanumerics unchanged" do
      expect(described_class.key_for("simple123")).to eq("simple123")
    end
  end

  describe ".overlay_suffix_pattern" do
    it "matches overlay file names" do
      expect("foo.qwen3-6-35b-a3b.md").to match(described_class::OVERLAY_SUFFIX_PATTERN)
      expect("bar.gemma4o.md").to match(described_class::OVERLAY_SUFFIX_PATTERN)
    end

    it "does not match base memory files" do
      expect("foo.md").not_to match(described_class::OVERLAY_SUFFIX_PATTERN)
      expect("foo.QWEN3-6-35B-A3B.md").not_to match(described_class::OVERLAY_SUFFIX_PATTERN)
    end
  end

  describe ".overlay_path_for" do
    it "returns correct path structure" do
      # Uses MemoryRead.memories_dir under the hood
      path = described_class.overlay_path_for("my_entry", "gemma4o", "system")
      expect(path).to end_with("my_entry.gemma4o.md")
    end

    it "returns nil when key is nil" do
      expect(described_class.overlay_path_for("my_entry", nil, "system")).to be_nil
    end

    it "returns nil when key is blank" do
      expect(described_class.overlay_path_for("my_entry", "", "system")).to be_nil
    end

    it "respects scope" do
      project_path = described_class.overlay_path_for("test", "key1", "project")
      system_path = described_class.overlay_path_for("test", "key1", "system")
      expect(project_path).to_not eq(system_path)
    end
  end
end
