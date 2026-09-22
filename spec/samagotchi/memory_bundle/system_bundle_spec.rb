# frozen_string_literal: true

require "spec_helper"
require "digest"
require "tmpdir"
require "samagotchi/memory_bundle/system_bundle"

RSpec.describe Samagotchi::MemoryBundle::SystemBundle do
  describe "shipped bundle manifest" do
    let(:dir) { described_class::GEM_BUNDLE_DIR }
    let(:manifest) { Samagotchi::MemoryBundle::Manifest.read(dir: dir) }

    it "lists every bundled memory file" do
      shipped = Dir.glob(File.join(dir, "*.md")).map { |p| File.basename(p) }.sort
      expect(manifest.files.keys.map(&:to_s).sort).to eq(shipped)
    end

    it "has checksums matching the bundled files (edit a file → refresh its sha256 and bump the version)" do
      manifest.files.each_key do |file_key|
        actual = Digest::SHA256.hexdigest(File.read(File.join(dir, file_key.to_s)))
        expect(manifest.checksum_for(file_key.to_s)).to eq(actual), "stale checksum for #{file_key}"
      end
    end
  end

  describe ".ensure!" do
    around do |example|
      Dir.mktmpdir("system-bundle-spec") do |tmp|
        @tmp = tmp
        old_xdg = ENV["XDG_CONFIG_HOME"]
        ENV["XDG_CONFIG_HOME"] = File.join(tmp, "config")
        example.run
      ensure
        ENV["XDG_CONFIG_HOME"] = old_xdg
      end
    end

    def ship(version, identity)
      dir = File.join(@tmp, "gem-#{version}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "identity.md"), identity)
      Samagotchi::MemoryBundle::Manifest.write(
        dir: dir, name: described_class::BUNDLE_NAME, version: version, scope: "system",
        files: { "identity.md" => "sha256:#{Digest::SHA256.hexdigest(identity)}" }
      )
      stub_const("#{described_class}::GEM_BUNDLE_DIR", dir)
    end

    def installed_version
      Samagotchi::MemoryBundle::Provenance.new(name: described_class::BUNDLE_NAME).read[:version].to_s
    end

    def installed_identity
      File.read(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
    end

    it "upgrades when the shipped bundle is newer" do
      ship("0.1.6", "old\n")
      described_class.ensure!
      ship("0.1.10", "new\n")
      described_class.ensure!

      expect(installed_version).to eq("0.1.10")
      expect(installed_identity).to eq("new\n")
    end

    it "leaves a newer installed bundle alone when the shipped one is older" do
      ship("0.1.7", "new\n")
      described_class.ensure!
      ship("0.1.6", "old\n")

      expect(described_class.ensure!).to be(false)
      expect(installed_version).to eq("0.1.7")
      expect(installed_identity).to eq("new\n")
    end

    it "does not restore a missing file from an older shipped bundle" do
      ship("0.1.7", "new\n")
      described_class.ensure!
      File.delete(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
      ship("0.1.6", "old\n")

      described_class.ensure!
      expect(installed_version).to eq("0.1.7")
      expect(File).not_to exist(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
    end
  end
end
