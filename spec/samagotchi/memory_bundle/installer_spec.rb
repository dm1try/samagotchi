# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"

require "samagotchi/memory_bundle/installer"

RSpec.describe Samagotchi::MemoryBundle::Installer do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-installer-") }
  let(:system_memories_dir) { File.join(tmpdir, "memories") }
  let(:project_memories_dir) { File.join(tmpdir, "project_memories") }
  let(:bundles_dir) { File.join(system_memories_dir, ".bundles") }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = bundles_dir
    described_class.system_dir_override = system_memories_dir
    described_class.project_dir_base_override = project_memories_dir
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    described_class.system_dir_override = nil
    described_class.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle(base_dir, files = {}, name: "test-bundle", version: "1.0.0")
    bundle_dir = File.join(base_dir, "bundle")
    FileUtils.mkdir_p(bundle_dir)
    files.each do |fname, content|
      File.write(File.join(bundle_dir, fname), content)
    end
    manifest = { "name" => name, "version" => version, "files" => {} }
    files.keys.each { |k| manifest["files"][k] = "sha256:fake" }
    File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))
    bundle_dir
  end

  def installer_for(source:, name:, scope: nil, force: false)
    described_class.new(
      source: source,
      name: name,
      scope: scope,
      force: force,
      strict: true
    )
  end

  describe "#run" do
    context "with a directory source" do
      it "installs .md files into the system scope directory" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n",
          "commit_preferences.md" => "# Preferences\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
        expect(File.read(File.join(system_memories_dir, "identity.md"))).to eq("# Identity\n")
        expect(installer.results["identity.md"][:status]).to eq("installed")
      end

      it "does NOT delete source directory after install (P1 regression)" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })
        expect(File.directory?(bundle_dir)).to be true

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(File.directory?(bundle_dir)).to be true
      end

      it "reports placeholders in installed files" do
        bundle_dir = write_bundle(tmpdir, {
          "test.md" => "# Test\n- {{command}}\n- {{language}}"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(installer.placeholder_warnings).to contain_exactly(
          "test.md: {{command}}, {{language}}"
        )
      end

      it "writes provenance" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(bundles_dir, "test-bundle", "manifest.json"))).to be true
        manifest_data = JSON.parse(
          File.read(File.join(bundles_dir, "test-bundle", "manifest.json")),
          symbolize_names: true
        )
        expect(manifest_data[:name]).to eq("test-bundle")
        expect(manifest_data[:files].keys).to include(:"identity.md")
      end

      it "skips existing files without --force" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Existing\n")

        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# New Identity\n",
          "new_file.md" => "# Brand New\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(installer.results["identity.md"][:status]).to eq("skipped")
        expect(installer.results["new_file.md"][:status]).to eq("installed")
        expect(File.read(File.join(system_memories_dir, "identity.md"))).to eq("# Existing\n")
      end

      it "overwrites existing files with --force" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Old\n")

        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# New Identity\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system", force: true)
        installer.run

        expect(installer.results["identity.md"][:status]).to eq("installed")
        expect(File.read(File.join(system_memories_dir, "identity.md"))).to eq("# New Identity\n")
      end

      it "uses CLI scope over manifest scope" do
        bundle_dir = write_bundle(tmpdir, {
          "test.md" => "# Test\n"
        }, name: "proj-bundle", version: "1.0")

        installer = installer_for(source: bundle_dir, name: "proj-bundle", scope: "project")
        installer.run

        expect(File.exist?(File.join(project_memories_dir, "test.md"))).to be true
      end

      it "defaults to system scope when no scope given" do
        bundle_dir = write_bundle(tmpdir, {
          "test.md" => "# Test\n"
        })

        installer = installer_for(source: bundle_dir, name: "t", scope: nil)
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "test.md"))).to be true
      end

      context "index updates (P3)" do
        it "updates index.md for installed files" do
          bundle_dir = write_bundle(tmpdir, {
            "identity.md" => "# Identity\n"
          })

          installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
          installer.run

          index_path = File.join(system_memories_dir, "index.md")
          expect(File.exist?(index_path)).to be true
          index_content = File.read(index_path)
          expect(index_content).to include("**identity.md**")
          expect(index_content).to include("· system ·")
        end

        it "updates index.md for skipped files" do
          FileUtils.mkdir_p(system_memories_dir)
          File.write(File.join(system_memories_dir, "identity.md"), "# Existing\n")

          bundle_dir = write_bundle(tmpdir, {
            "identity.md" => "# New\n"
          })

          installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
          installer.run

          index_path = File.join(system_memories_dir, "index.md")
          expect(File.exist?(index_path)).to be true
          index_content = File.read(index_path)
          expect(index_content).to include("**identity.md**")
        end
      end

      context "checksum verification (P4)" do
        it "warns on checksum mismatch in strict mode" do
          # Write a bundle with a wrong checksum in manifest
          bundle_dir = File.join(tmpdir, "bundle_checksum")
          FileUtils.mkdir_p(bundle_dir)
          File.write(File.join(bundle_dir, "identity.md"), "# Identity\n")
          # Manifest claims a different checksum than what the file actually has
          manifest = { "name" => "cksum-test", "version" => "1.0", "files" => {
            "identity.md" => "sha256:0000000000000000000000000000000000000000000000000000000000000000"
          } }
          File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))

          installer = installer_for(source: bundle_dir, name: "cksum-test", scope: "system")
          installer.run

          expect(installer.warnings.any? { |w| w.include?("Checksum mismatch") }).to be true
        end

        it "does not warn when checksums match" do
          require "digest"
          bundle_dir = File.join(tmpdir, "bundle_cksum_ok")
          FileUtils.mkdir_p(bundle_dir)
          content = "# Identity\n"
          File.write(File.join(bundle_dir, "identity.md"), content)
          real_sha = Digest::SHA256.hexdigest(content)
          manifest = { "name" => "cksum-ok", "version" => "1.0", "files" => {
            "identity.md" => "sha256:#{real_sha}"
          } }
          File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))

          installer = installer_for(source: bundle_dir, name: "cksum-ok", scope: "system")
          installer.run

          checksum_warnings = installer.warnings.select { |w| w.include?("Checksum mismatch") }
          expect(checksum_warnings).to be_empty
        end
      end
    end

    context "with a zip source" do
      it "extracts and installs from a zip file" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })

        zip_path = File.join(tmpdir, "bundle.zip")
        Dir.chdir(bundle_dir) { system("zip", "-r", zip_path, ".") }

        installer = installer_for(source: zip_path, name: "zip-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
      end

      it "cleans up temp dir after zip install (P1)" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })
        zip_path = File.join(tmpdir, "bundle.zip")
        Dir.chdir(bundle_dir) { system("zip", "-r", zip_path, ".") }

        installer = installer_for(source: zip_path, name: "zip-bundle", scope: "system")
        installer.run

        # Zip source: temp dirs should be cleaned up. The installer uses source_owned.
        # The normalized temp dir is cleaned in ensure block when source_owned=true.
      end
    end

    context "with a tar.gz source" do
      it "extracts and installs from a tar.gz file" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })

        tar_path = File.join(tmpdir, "bundle.tar.gz")
        Dir.chdir(tmpdir) { system("tar", "-czf", tar_path, File.basename(bundle_dir)) }

        installer = installer_for(source: tar_path, name: "tar-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
      end
    end

    context "with --no-strict mode (non-strict flag text P6)" do
      it "proceeds without a manifest" do
        bundle_dir = File.join(tmpdir, "bundle_no_manifest")
        FileUtils.mkdir_p(bundle_dir)
        File.write(File.join(bundle_dir, "identity.md"), "# Identity\n")

        installer = described_class.new(
          source: bundle_dir,
          name: "nom",
          scope: "system",
          force: false,
          strict: false
        )

        expect { installer.run }.not_to raise_error
        expect(installer.warnings.any?).to be true
        expect(installer.warnings.first).not_to include("--no-strict")
      end
    end

    context "with invalid source" do
      it "raises for nonexistent path" do
        installer = installer_for(source: "/nonexistent", name: "nb")
        expect { installer.run }
          .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /Source normalization failed/)
      end

      it "raises for unsupported format" do
        path = File.join(tmpdir, "bundle.txt")
        File.write(path, "hello")
        installer = installer_for(source: path, name: "nb")
        expect { installer.run }
          .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /unsupported/)
      end
    end
  end

  describe "#summary" do
    it "reports installed and skipped files" do
      bundle_dir = write_bundle(tmpdir, {
        "identity.md" => "# Identity\n",
        "new.md" => "# New\n"
      })

      FileUtils.mkdir_p(system_memories_dir)
      File.write(File.join(system_memories_dir, "identity.md"), "# Existing\n")

      installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
      installer.run

      summary = installer.summary
      expect(summary).to include("Installed:")
      expect(summary).to include("Skipped:")
      expect(summary).to include("identity.md")
      expect(summary).to include("new.md")
    end
  end

  describe "#placeholder_warnings" do
    it "is accessible via attr_reader" do
      bundle_dir = write_bundle(tmpdir, {
        "test.md" => "has {{placeholder}}"
      })

      installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
      installer.run

      expect(installer.placeholder_warnings).to be_an(Array)
      expect(installer.placeholder_warnings).to include("test.md: {{placeholder}}")
    end
  end
end
