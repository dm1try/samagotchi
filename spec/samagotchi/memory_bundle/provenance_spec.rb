# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/provenance"

RSpec.describe Samagotchi::MemoryBundle::Provenance do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-prov-") }
  let(:bundles_dir) { File.join(tmpdir, ".bundles") }
  before do
    described_class.bundles_dir_override = bundles_dir
  end
  after do
    described_class.bundles_dir_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  def make_file(base_dir, name, content)
    path = File.join(base_dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  describe "#write" do
    it "writes manifest.json and base snapshots" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "identity.md", "# Identity\nLine 2\n")
      f2 = make_file(base_dir, "commit_preferences.md", "# Preferences\n")
      prov.write(
        files: { "identity.md" => f1, "commit_preferences.md" => f2 },
        scope: "system",
        version: "1.0.0",
        source_path: "/some/path"
      )
      manifest = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(manifest[:name]).to eq("test-bundle")
      expect(manifest[:version]).to eq("1.0.0")
      expect(manifest[:scope]).to eq("system")
      expect(manifest[:source]).to eq("/some/path")
      expect(manifest[:installed_at]).not_to be_nil
      expect(manifest[:files].keys).to contain_exactly(:"identity.md", :"commit_preferences.md")
      # Check base snapshots exist and match content (no double extension).
      expect(File.read(prov.base_path("identity.md"))).to eq("# Identity\nLine 2\n")
      expect(File.exist?(File.join(prov.bundle_dir, "bases", "identity.md"))).to be true
      expect(File.read(prov.base_path("commit_preferences.md"))).to eq("# Preferences\n")
    end

    it "computes SHA256 checksums" do
      prov = described_class.new(name: "test-bundle")
      f = make_file(tmpdir, "foo.md", "hello world")
      expected_sha = Digest::SHA256.hexdigest("hello world")
      prov.write(files: { "foo.md" => f }, scope: "system", version: "1.0", source_path: "/x")
      manifest = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      key = :"foo.md"
      expect(manifest[:files][key][:checksum]).to eq(expected_sha)
    end

    it "merges file entries on re-install (P2: no clobber)" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "a.md", "AAA")
      f2 = make_file(base_dir, "b.md", "BBB")

      # First install with two files.
      prov.write(files: { "a.md" => f1, "b.md" => f2 }, scope: "system", version: "1.0", source_path: "/x")
      m1 = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m1[:files].keys).to contain_exactly(:"a.md", :"b.md")

      # Re-install with only one file — old file entry should be pruned.
      f3 = make_file(base_dir, "a.md", "AAA v2")
      prov.write(files: { "a.md" => f3 }, scope: "system", version: "1.1", source_path: "/x")
      m2 = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m2[:files].keys).to contain_exactly(:"a.md")
      expect(File.exist?(File.join(prov.bundle_dir, "bases", "b.md"))).to be false
    end

    it "preserves untouched entries on merge" do
      prov = described_class.new(name: "test-bundle")
      base_dir = File.join(tmpdir, "sources")
      f1 = make_file(base_dir, "a.md", "AAA")
      f2 = make_file(base_dir, "b.md", "BBB")
      f3 = make_file(base_dir, "c.md", "CCC")

      # First install: a, b
      prov.write(files: { "a.md" => f1, "b.md" => f2 }, scope: "system", version: "1.0", source_path: "/x")

      # Re-install: a (updated), c (new) — b should be pruned
      prov.write(files: { "a.md" => f3, "c.md" => f3 }, scope: "system", version: "1.1", source_path: "/x")
      m = JSON.parse(File.read(prov.bundle_dir + "/manifest.json"), symbolize_names: true)
      expect(m[:files].keys).to contain_exactly(:"a.md", :"c.md")
    end
  end

  describe "#read" do
    it "returns nil when not installed" do
      prov = described_class.new(name: "nonexistent")
      expect(prov.read).to be_nil
    end

    it "returns parsed manifest when installed" do
      prov = described_class.new(name: "test-bundle")
      prov.write(files: {}, scope: "project", version: "2.0", source_path: "/src")
      data = prov.read
      expect(data[:name]).to eq("test-bundle")
      expect(data[:version]).to eq("2.0")
    end
  end

  describe "#installed?" do
    it "is false when not installed" do
      expect(described_class.new(name: "missing").installed?).to be false
    end

    it "is true when installed" do
      prov = described_class.new(name: "test-bundle")
      prov.write(files: {}, scope: "system", version: "1.0", source_path: "/x")
      expect(prov.installed?).to be true
    end
  end

  describe "#base_path" do
    it "returns the correct path for a file key (no double .md)" do
      prov = described_class.new(name: "my-bundle")
      # file_key is "identity.md", base should be "bases/identity.md" NOT "bases/identity.md.md"
      expect(prov.base_path("identity.md")).to include("bases", "identity.md")
      # Verify it doesn't double up
      expect(prov.base_path("identity.md")).not_to end_with(".md.md")
    end
  end

  describe "hooks" do
    it "returns hooks_dir" do
      prov = described_class.new(name: "my-bundle")
      expect(prov.hooks_dir).to eq(File.join(bundles_dir, "my-bundle", "hooks"))
    end

    it "write/read round-trips hooks map and trust_level + source_commit (experimental must survive)" do
      prov = described_class.new(name: "hook-bundle")
      prov.write(files: {}, scope: "system", version: "1.0", source_path: "/src",
                 hooks: { "guardrails.rb" => { "sha256" => "sha256:abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } },
                 trust_level: "experimental", source_commit: "deadbeef")
      data = prov.read
      expect(data[:hooks]).to include(:"guardrails.rb")
      expect(data[:trust_level]).to eq("experimental")
      expect(data[:source_commit]).to eq("deadbeef")
    end

    it "each_installed_holding_hooks yields only hook-bearing bundles" do
      p1 = described_class.new(name: "with-hooks")
      p1.write(files: {}, scope: "system", version: "1.0", source_path: "/src",
               hooks: { "a.rb" => { "sha256" => "sha256:x", "event" => "e", "on_error" => "skip", "priority" => 100 } })
      p2 = described_class.new(name: "without-hooks")
      p2.write(files: {}, scope: "system", version: "1.0", source_path: "/src")
      names = []
      described_class.each_installed_holding_hooks { |n, _d| names << n }
      expect(names).to include("with-hooks")
      expect(names).not_to include("without-hooks")
    end

    it "each_installed_holding_hooks is no-op for empty/absent dir" do
      FileUtils.rm_rf(bundles_dir)
      expect { |b| described_class.each_installed_holding_hooks(&b) }.not_to yield_control
      expect(described_class.each_installed_holding_hooks.to_a).to be_empty
    end

    it "each_installed_holding_hooks returns enum when no block" do
      enum = described_class.each_installed_holding_hooks
      expect(enum).to be_a(Enumerator)
    end
  end
end
