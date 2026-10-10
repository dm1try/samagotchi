# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "samagotchi/bundle_needs"
require "samagotchi/muted_memories"

RSpec.describe Samagotchi::BundleNeeds do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-needs-") }

  after { FileUtils.rm_rf(tmpdir) }

  def make_file(dir, name, mode)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    File.chmod(mode, path)
    path
  end

  describe ".found?" do
    it "finds an executable file in any PATH folder" do
      bin = File.join(tmpdir, "bin")
      make_file(bin, "fakecmd", 0o755)
      expect(described_class.found?("fakecmd", path: ["/nonexistent", bin].join(File::PATH_SEPARATOR))).to be(true)
    end

    it "doesn't count a file that isn't executable" do
      make_file(tmpdir, "fakecmd", 0o644)
      expect(described_class.found?("fakecmd", path: tmpdir)).to be(false)
    end

    it "doesn't count a directory with that name" do
      FileUtils.mkdir_p(File.join(tmpdir, "fakecmd"))
      File.chmod(0o755, File.join(tmpdir, "fakecmd"))
      expect(described_class.found?("fakecmd", path: tmpdir)).to be(false)
    end

    it "finds nothing on an empty or missing PATH" do
      expect(described_class.found?("sh", path: "")).to be(false)
      expect(described_class.found?("sh", path: nil)).to be(false)
    end
  end

  describe ".missing and .marker" do
    it "keeps only the needs not found and names them in the marker" do
      make_file(tmpdir, "here", 0o755)
      needs = [{ command: "here" }, { command: "gone1" }, { command: "gone2" }]
      missing = described_class.missing(needs, path: tmpdir)
      expect(missing.map { |n| n[:command] }).to eq(%w[gone1 gone2])
      expect(described_class.marker(missing)).to eq("[needs gone1, gone2: not found on PATH]")
    end

    it "has no marker when nothing is missing" do
      expect(described_class.marker([])).to be_nil
    end
  end

  describe ".annotate_index" do
    let(:bundles_dir) { File.join(tmpdir, ".bundles") }
    let(:index) do
      "# Memory index\n\n- **gh_helper** · system · 2026-09-26 · 120 — GitHub via gh\n" \
        "- **other** · system · 2026-09-26 · 40\n- **legacy.md** · old line\r\n"
    end

    def install(name, scope:, files:, needs:)
      dir = File.join(bundles_dir, name)
      FileUtils.mkdir_p(dir)
      data = { "name" => name, "scope" => scope, "files" => files.to_h { |f| [f, { "checksum" => "x" }] } }
      data["needs"] = needs if needs
      File.write(File.join(dir, "manifest.json"), JSON.generate(data))
    end

    def annotate(text = index, scope: "system")
      described_class.annotate_index(text, scope, path: "/usr/bin:/bin", bundles_dir: bundles_dir)
    end

    it "marks only the lines of the bundle with a missing need, keeping every other byte" do
      install("needs", scope: "system", files: %w[gh_helper.md legacy.md], needs: [{ "command" => "chi-nope" }, { "command" => "sh" }])
      install("fine", scope: "system", files: %w[other.md], needs: [{ "command" => "sh" }])
      expect(annotate).to eq(
        "# Memory index\n\n- **gh_helper** · system · 2026-09-26 · 120 — GitHub via gh [needs chi-nope: not found on PATH]\n" \
          "- **other** · system · 2026-09-26 · 40\n- **legacy.md** · old line [needs chi-nope: not found on PATH]\r\n"
      )
    end

    it "marks a bare name in the no-index-yet list" do
      install("needs", scope: "system", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      expect(annotate("Stored memories (no index yet):\ngh_helper\nother")).to eq(
        "Stored memories (no index yet):\ngh_helper [needs chi-nope: not found on PATH]\nother"
      )
    end

    it "counts a bundle with no recorded scope as a system one" do
      install("needs", scope: nil, files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      expect(annotate).to include("gh_helper** · system · 2026-09-26 · 120 — GitHub via gh [needs chi-nope: not found on PATH]")
      expect(annotate(scope: "project")).to equal(index)
    end

    it "ignores a bundle of the other scope" do
      install("needs", scope: "project", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      expect(annotate).to equal(index)
    end

    it "leaves a muted (filtered-out) line gone" do
      install("needs", scope: "system", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      filtered = Samagotchi::MutedMemories.filter_index(index, ["gh_helper"])
      expect(annotate(filtered)).not_to include("gh_helper")
    end

    it "returns the same text when no bundle has needs or none is missing" do
      install("plain", scope: "system", files: %w[gh_helper.md], needs: nil)
      install("fine", scope: "system", files: %w[other.md], needs: [{ "command" => "sh" }])
      expect(annotate).to equal(index)
    end

    it "skips a broken manifest.json and still marks the others" do
      FileUtils.mkdir_p(File.join(bundles_dir, "broken"))
      File.write(File.join(bundles_dir, "broken", "manifest.json"), "{nope")
      expect(annotate).to equal(index)
      install("needs", scope: "system", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      expect(annotate).to include("gh_helper** · system · 2026-09-26 · 120 — GitHub via gh [needs chi-nope")
    end

    it "skips a bundle whose stored needs don't parse" do
      install("bad", scope: "system", files: %w[other.md], needs: [{ "command" => "/bad path" }])
      install("needs", scope: "system", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      expect(annotate).to include("GitHub via gh [needs chi-nope").and include("- **other** · system · 2026-09-26 · 40\n")
    end

    it "returns the text unchanged on an unexpected error" do
      install("needs", scope: "system", files: %w[gh_helper.md], needs: [{ "command" => "chi-nope" }])
      allow(Dir).to receive(:children).and_raise(Errno::EACCES)
      expect(annotate).to equal(index)
    end
  end
end
