# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "samagotchi/memory_bundle/source"

RSpec.describe Samagotchi::MemoryBundle::SourceNormalizer do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-srcnorm-") }
  after { FileUtils.rm_rf(tmpdir) }

  def write_bundle_dir(base_dir, files = {})
    bundle_dir = File.join(base_dir, "bundle")
    FileUtils.mkdir_p(bundle_dir)
    files.each do |name, content|
      File.write(File.join(bundle_dir, name), content)
    end
    manifest = {
      "name" => "test-bundle",
      "version" => "1.0.0",
      "files" => {}
    }
    files.keys.each { |k| manifest["files"][k] = "sha256:fake" }
    File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))
    bundle_dir
  end

  describe ".normalize" do
    it "returns a directory as-is with owned=false" do
      base = write_bundle_dir(tmpdir, "identity.md" => "# Identity\n")
      path, owned = described_class.normalize(base)
      expect(path).to eq(File.expand_path(base))
      expect(owned).to be false
    end

    it "raises for nonexistent source" do
      expect { described_class.normalize("/nonexistent/path") }
        .to raise_error(Samagotchi::MemoryBundle::SourceNormalizer::UnknownSourceError)
    end

    it "raises for unsupported extensions" do
      path = File.join(tmpdir, "bundle.txt")
      File.write(path, "hello")
      expect { described_class.normalize(path) }
        .to raise_error(Samagotchi::MemoryBundle::SourceNormalizer::UnknownSourceError, /unsupported/)
    end

    context "zip files" do
      it "extracts a zip to a clean directory with owned=true" do
        bundle_dir = write_bundle_dir(tmpdir,
          "identity.md" => "# Identity\n",
          "commit_preferences.md" => "# Commit Preferences\n"
        )
        zip_path = File.join(tmpdir, "bundle.zip")
        Dir.chdir(bundle_dir) { system("zip", "-r", zip_path, ".") }
        path, owned = described_class.normalize(zip_path)
        expect(File.exist?(File.join(path, "identity.md"))).to be true
        expect(File.exist?(File.join(path, "commit_preferences.md"))).to be true
        expect(File.exist?(File.join(path, "manifest.yml"))).to be true
        expect(owned).to be true
        described_class.cleanup(path)
      end

      it "handles zip with top-level directory" do
        bundle_dir = write_bundle_dir(tmpdir,
          "identity.md" => "# Identity\n"
        )
        zip_path = File.join(tmpdir, "bundle2.zip")
        Dir.chdir(tmpdir) { system("zip", "-r", zip_path, File.basename(bundle_dir)) }
        path, owned = described_class.normalize(zip_path)
        expect(File.exist?(File.join(path, "identity.md"))).to be true
        expect(owned).to be true
        described_class.cleanup(path)
      end
    end

    context "tar.gz files" do
      it "extracts a tar.gz to a clean directory" do
        bundle_dir = write_bundle_dir(tmpdir,
          "identity.md" => "# Identity\n",
          "commit_preferences.md" => "# Commit Preferences\n"
        )
        tar_path = File.join(tmpdir, "bundle.tar.gz")
        Dir.chdir(tmpdir) { system("tar", "-czf", tar_path, File.basename(bundle_dir)) }
        path, owned = described_class.normalize(tar_path)
        expect(File.exist?(File.join(path, "identity.md"))).to be true
        expect(File.exist?(File.join(path, "commit_preferences.md"))).to be true
        expect(owned).to be true
        described_class.cleanup(path)
      end

      it "handles .tgz extension" do
        bundle_dir = write_bundle_dir(tmpdir,
          "test.md" => "# Test\n"
        )
        tgz_path = File.join(tmpdir, "bundle.tgz")
        Dir.chdir(tmpdir) { system("tar", "-czf", tgz_path, File.basename(bundle_dir)) }
        path, owned = described_class.normalize(tgz_path)
        expect(File.exist?(File.join(path, "test.md"))).to be true
        expect(owned).to be true
        described_class.cleanup(path)
      end
    end
  end

  describe ".cleanup" do
    it "removes a directory" do
      d = Dir.mktmpdir
      described_class.cleanup(d)
      expect(File.directory?(d)).to be false
    end

    it "handles nil gracefully" do
      expect { described_class.cleanup(nil) }.not_to raise_error
    end

    it "handles nonexistent dir gracefully" do
      expect { described_class.cleanup("/nonexistent") }.not_to raise_error
    end
  end

  describe "ownership semantics" do
    it "does not delete source dir when installing from a directory" do
      bundle_dir = write_bundle_dir(tmpdir, "identity.md" => "# Identity\n")
      _, owned = described_class.normalize(bundle_dir)
      expect(owned).to be false
      expect(File.directory?(bundle_dir)).to be true
    end

    it "returns owned=true for archive sources" do
      bundle_dir = write_bundle_dir(tmpdir, "identity.md" => "# Identity\n")
      zip_path = File.join(tmpdir, "bundle.zip")
      Dir.chdir(bundle_dir) { system("zip", "-r", zip_path, ".") }
      _, owned = described_class.normalize(zip_path)
      expect(owned).to be true
    end
  end
end
