# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
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
    let(:pattern) { described_class::OVERLAY_SUFFIX_PATTERN }

    it "matches overlay file names" do
      expect(pattern).to match("foo.qwen3-6-35b-a3b.md")
      expect(pattern).to match("bar.gemma4o.md")
    end

    it "does not match base memory files" do
      expect(pattern).not_to match("foo.md")
      expect(pattern).not_to match("foo.QWEN3-6-35B-A3B.md")
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
      expect(project_path).not_to eq(system_path)
    end
  end

  describe ".overlay_file?" do
    let(:dir) { Dir.mktmpdir("overlay-file-") }

    after { FileUtils.rm_rf(dir) }

    it "is an overlay when <stem>.md is next to it (the default base dir)" do
      File.write(File.join(dir, "tips.md"), "base")
      expect(described_class.overlay_file?(File.join(dir, "tips.qwen3.md"))).to be(true)
    end

    it "isn't one without a base, or without the suffix pattern" do
      expect(described_class.overlay_file?(File.join(dir, "tips.qwen3.md"))).to be(false)
      File.write(File.join(dir, "tips.md"), "base")
      expect(described_class.overlay_file?(File.join(dir, "tips.md"))).to be(false)
      expect(described_class.overlay_file?(File.join(dir, "tips.QWEN.md"))).to be(false)
      expect(described_class.overlay_file?(File.join(dir, "index.md"))).to be(false)
    end

    it "finds the base in any of base_dirs, or among base_names" do
      other = Dir.mktmpdir("overlay-base-")
      File.write(File.join(other, "tips.md"), "base")
      path = File.join(dir, "tips.qwen3.md")
      expect(described_class.overlay_file?(path, base_dirs: [dir])).to be(false)
      expect(described_class.overlay_file?(path, base_dirs: [dir, other])).to be(true)
      expect(described_class.overlay_file?(path, base_dirs: [], base_names: ["tips.md"])).to be(true)
      expect(described_class.overlay_file?(path, base_dirs: [], base_names: ["other.md"])).to be(false)
    ensure
      FileUtils.rm_rf(other)
    end

    it "takes a bare file name too" do
      expect(described_class.overlay_file?("tips.qwen3.md", base_dirs: [], base_names: ["tips.md"])).to be(true)
    end
  end

  describe ".bundle_overlay?" do
    let(:target) { Dir.mktmpdir("overlay-target-") }

    after { FileUtils.rm_rf(target) }

    it "is one when the bundle has the base, the base is nowhere, or only the target has it (an installed memory)" do
      expect(described_class.bundle_overlay?("tips.qwen3.md", bundle_files: ["tips.md"], target_dir: target)).to be(true)
      expect(described_class.bundle_overlay?("tips.qwen3.md", bundle_files: [], target_dir: target)).to be(true)
      File.write(File.join(target, "tips.md"), "mine")
      expect(described_class.bundle_overlay?("tips.qwen3.md", bundle_files: [], target_dir: target)).to be(true)
      expect(described_class.bundle_overlay?("tips.md", bundle_files: ["tips.md"], target_dir: target)).to be(false)
    end
  end
end
