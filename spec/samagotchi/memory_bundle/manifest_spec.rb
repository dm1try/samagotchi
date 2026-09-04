# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/manifest"

RSpec.describe Samagotchi::MemoryBundle::Manifest do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-manifest-") }
  after { FileUtils.rm_rf(tmpdir) }

  def write_manifest(attrs)
    attrs = attrs.dup.transform_keys(&:to_s)
    attrs["name"] ||= "test-bundle"
    attrs["version"] ||= "1.0.0"
    attrs["files"] ||= {}
    manifest_path = File.join(tmpdir, "manifest.yml")
    File.write(manifest_path, YAML.dump(attrs))
    manifest_path
  end

  describe "#initialize" do
    it "parses a valid manifest" do
      path = write_manifest({
        "name" => "my-bundle",
        "version" => "2.1.0",
        "scope" => "system",
        "description" => "A test bundle",
        "files" => {
          "identity.md" => "sha256:abc123",
          "commit_preferences.md" => "def456"
        }
      })
      manifest = described_class.new(path: path)
      expect(manifest.name).to eq("my-bundle")
      expect(manifest.version).to eq("2.1.0")
      expect(manifest.scope).to eq("system")
      expect(manifest.description).to eq("A test bundle")
      expect(manifest.checksum_for("identity.md")).to eq("abc123")
      expect(manifest.checksum_for("commit_preferences.md")).to eq("def456")
    end

    it "strips sha256: prefix from checksum_for when present" do
      path = write_manifest({
        "files" => { "foo.md" => "sha256:abcdef012345" }
      })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("foo.md")).to eq("abcdef012345")
    end

    it "returns bare hex when no prefix" do
      path = write_manifest({
        "files" => { "foo.md" => "abcdef012345" }
      })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("foo.md")).to eq("abcdef012345")
    end

    it "returns nil for unknown file key" do
      path = write_manifest({ "files" => { "foo.md" => "sha256:abc" } })
      manifest = described_class.new(path: path)
      expect(manifest.checksum_for("bar.md")).to be_nil
    end

    it "defaults scope to nil when not provided" do
      path = write_manifest({})
      manifest = described_class.new(path: path)
      expect(manifest.scope).to be_nil
    end

    it "rejects invalid scope values" do
      path = write_manifest({ "scope" => "invalid" })
      manifest = described_class.new(path: path)
      expect(manifest.scope).to be_nil
    end

    it "raises on missing required fields" do
      File.write(File.join(tmpdir, "manifest.yml"), YAML.dump({}))
      expect { described_class.new(path: File.join(tmpdir, "manifest.yml")) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /name/)
    end

    it "ignores empty file keys" do
      path = write_manifest({ "files" => { "" => "sha256:abc", "valid.md" => "sha256:def" } })
      manifest = described_class.new(path: path)
      expect(manifest.files).to eq({ "valid.md" => "sha256:def" })
    end
  end

  describe ".read" do
    it "reads from a directory" do
      write_manifest({})
      manifest = described_class.read(dir: tmpdir)
      expect(manifest.name).to eq("test-bundle")
    end

    it "raises when no manifest.yml in dir" do
      expect { described_class.read(dir: tmpdir) }
        .to raise_error(Samagotchi::MemoryBundle::Manifest::ValidationError, /not found/)
    end
  end

  describe ".write" do
    it "writes a valid manifest.yml" do
      dest = File.join(tmpdir, "output")
      described_class.write(
        dir: dest,
        name: "new-bundle",
        version: "1.0.0",
        scope: "project",
        description: "Created by test",
        files: { "test.md" => "sha256:xyz789" }
      )
      manifest = described_class.read(dir: dest)
      expect(manifest.name).to eq("new-bundle")
      expect(manifest.version).to eq("1.0.0")
      expect(manifest.scope).to eq("project")
      expect(manifest.description).to eq("Created by test")
      expect(manifest.checksum_for("test.md")).to eq("xyz789")
    end

    it "omits scope from yaml when nil" do
      dest = File.join(tmpdir, "output2")
      described_class.write(dir: dest, name: "n", version: "1", scope: nil, files: {})
      content = File.read(File.join(dest, "manifest.yml"))
      expect(content).not_to include("scope:")
    end
  end
end
