# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "samagotchi/memory_bundle/memory_files"
require "samagotchi/memory_bundle/manifest"

RSpec.describe Samagotchi::MemoryBundle::MemoryFiles do
  describe ".repo_meta?" do
    it "matches a repo's meta files in any case, with .md, .markdown, .txt or no extension" do
      %w[README README.md readme.markdown LICENSE.txt Licence CHANGELOG.md Contributing.md CODE_OF_CONDUCT.md
         security.md].each { |name| expect(described_class.repo_meta?(name)).to be(true), name }
    end

    it "leaves memories alone, readme-like names included" do
      %w[identity.md readme_notes.md my_license.md security_review.md README.rst.md].each do |name|
        expect(described_class.repo_meta?(name)).to be(false), name
      end
    end
  end

  describe "symlinks" do
    around do |example|
      Dir.mktmpdir("memory-files-") do |dir|
        @dir = dir
        example.run
      end
    end

    def bundle(listed: nil)
      dir = File.join(@dir, "b")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "real.md"), "# Real\n")
      File.write(File.join(@dir, "secret.txt"), "SECRET\n")
      File.symlink(File.join(@dir, "secret.txt"), File.join(dir, "notes.md"))
      File.symlink("real.md", File.join(dir, "alias.md"))
      raw = { "name" => "b", "version" => "1.0.0" }
      raw["files"] = listed.to_h { |f| [f, "sha256:x"] } if listed
      File.write(File.join(dir, "manifest.yml"), YAML.dump(raw))
      [dir, Samagotchi::MemoryBundle::Manifest.read(dir: dir)]
    end

    it "selects no symlinked *.md (outside the bundle or not) and names them in .symlinks" do
      dir, manifest = bundle
      expect(described_class.select(dir, manifest)).to eq(["real.md"])
      expect(described_class.symlinks(dir, manifest)).to eq(%w[alias.md notes.md])
    end

    it "with a files: list too: a listed symlink is in .symlinks, not .select or .unshipped" do
      dir, manifest = bundle(listed: %w[real.md notes.md gone.md])
      expect(described_class.select(dir, manifest)).to eq(["real.md"])
      expect(described_class.symlinks(dir, manifest)).to eq(["notes.md"])
      expect(described_class.unshipped(dir, manifest)).to eq(["gone.md"])
    end
  end
end
