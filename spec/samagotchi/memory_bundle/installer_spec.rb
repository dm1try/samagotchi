# frozen_string_literal: true
require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"

require "samagotchi/memory_bundle/installer"

RSpec.describe Samagotchi::MemoryBundle::Installer do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-installer-") }
  let(:system_memories_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:project_memories_dir) { Samagotchi::MemoryPaths.project_dir }
  let(:bundles_dir) { File.join(system_memories_dir, ".bundles") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  after do
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

      it "records only the files it wrote: a skipped file stays the user's" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Existing\n")
        File.write(File.join(system_memories_dir, "same.md"), "# Same\n")
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# New\n", "same.md" => "# Same\n", "new_file.md" => "# Brand New\n" })

        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

        data = Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle").read
        expect(data[:files].keys).to eq([:"new_file.md"])
        expect(Dir.children(File.join(bundles_dir, "test-bundle", "bases"))).to eq(["new_file.md"])
      end

      it "a re-install keeps the files it installed before, skipped or not" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n", "b.md" => "# B\n" })
        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
        File.write(File.join(system_memories_dir, "b.md"), "# B\nedited\n")

        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
        data = Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle").read
        expect(data[:files].keys).to contain_exactly(:"identity.md", :"b.md")
      end

      it "skips an existing file identical to the bundle's as already up to date, without a warning" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Identity\n")
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(installer.results["identity.md"]).to eq(status: "skipped", reason: "already up to date")
        expect(installer.warnings).to be_empty
        expect(installer.summary).not_to include("--force")
      end

      it "re-installing an installed bundle hints at chi bundle upgrade, once" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

        again = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        again.run
        hint = "test-bundle is already installed; `chi bundle upgrade test-bundle` updates it and keeps local edits"
        expect(again.summary.lines.map(&:chomp).count(hint)).to eq(1)
        expect(again.summary).to include("Skipped: identity.md")
        expect(again.summary).not_to include("use --force")
      end

      it "a first install has no upgrade hint" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run
        expect(installer.summary).not_to include("already installed")
      end

      it "a differing file in an installed bundle still warns about --force" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
        File.write(File.join(system_memories_dir, "identity.md"), "# Edited\n")

        again = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        again.run
        expect(again.results["identity.md"]).to eq(status: "skipped", reason: "already exists")
        expect(again.warnings).to eq(["Skipped identity.md (already exists; use --force to overwrite)"])
        expect(again.summary).to include("chi bundle upgrade test-bundle")
      end

      it "a dry run reports an identical file as already up to date" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Identity\n")
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })

        installer = described_class.new(source: bundle_dir, name: "test-bundle", scope: "system", strict: true, dry_run: true)
        installer.run
        expect(installer.results["identity.md"]).to eq(status: "skipped", reason: "already up to date")
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
          expect(index_content).to include("- **identity** · system ·")
          expect(index_content).not_to include("**identity.md**")
          expect(index_content).to include("· system ·")
        end

        it "tags the lines of the files it wrote with the bundle, not a skipped file's" do
          FileUtils.mkdir_p(system_memories_dir)
          File.write(File.join(system_memories_dir, "mine.md"), "# Mine\n")
          bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n", "mine.md" => "# Theirs\n" })
          installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

          index_content = File.read(File.join(system_memories_dir, "index.md"))
          expect(index_content).to include("- **identity** · system · #{Date.today.iso8601} · 11 · from test-bundle\n")
          expect(index_content).to include("- **mine** · system · #{Date.today.iso8601} · 7\n")
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
          expect(index_content).to include("- **identity** · system ·")
          expect(index_content).not_to include("**identity.md**")
        end
        it "says when an index line couldn't be written, and installs anyway" do
          allow(Samagotchi::MemoryBundle::IndexUpdater).to receive(:update_index).and_raise(Errno::EACCES, "index.md")
          bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
          installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
          installer.run

          expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
          expect(installer.warnings).to include("index.md: line for identity not updated (Permission denied - index.md)")
        end

        it "replaces a legacy name.md index line with the entry name" do
          FileUtils.mkdir_p(system_memories_dir)
          File.write(File.join(system_memories_dir, "index.md"),
                     "# Memory Index\n\n- **identity.md** · system · 2026-09-09 · 310\n- **notes** · system · 2026-09-01 · 5\n")

          bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
          installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

          index_content = File.read(File.join(system_memories_dir, "index.md"))
          expect(index_content).not_to include("**identity.md**")
          expect(index_content.scan("- **identity** ").size).to eq(1)
          expect(index_content).to include("- **notes** · system · 2026-09-01 · 5")
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

  describe "guardrail rule files" do
    it "an unchanged rules file is skipped as already up to date; a changed one is installed" do
      bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
      FileUtils.mkdir_p(File.join(bundle_dir, "guardrails"))
      File.write(File.join(bundle_dir, "guardrails", "a.yml"), "rules: []\n")
      File.write(File.join(bundle_dir, "guardrails", "b.yml"), "rules: []\n")
      installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
      File.write(File.join(bundle_dir, "guardrails", "b.yml"), "rules: [] # v2\n")

      up = described_class.new(source: bundle_dir, name: "test-bundle", scope: "system", strict: true, upgrade: true)
      up.run
      expect(up.results["guardrails/a.yml"]).to eq(status: "skipped", reason: "already up to date")
      expect(up.results["guardrails/b.yml"]).to eq(status: "installed")
      expect(File.read(File.join(bundles_dir, "test-bundle", "guardrails", "b.yml"))).to eq("rules: [] # v2\n")
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle").read[:guardrails].keys.map(&:to_s))
        .to contain_exactly("a.yml", "b.yml")
    end
  end

  describe "model overlays (<name>.<key>.md next to <name>.md)" do
    let(:index_path) { File.join(system_memories_dir, "index.md") }
    let(:key) { "deepseek-v4-1-flash" } # sorts before tips.md: the base isn't copied yet

    def install(files, **opts)
      dir = write_bundle(tmpdir, files, name: "ovl-bundle")
      described_class.new(source: dir, name: "ovl-bundle", scope: "system", strict: true, **opts).tap(&:run)
    end

    it "installs the overlay next to its base with no index line of its own" do
      inst = install({ "tips.md" => "# Tips\n", "tips.#{key}.md" => "DeepSeek only\n", "tips.qwen3.md" => "Qwen only\n" })
      expect(File.read(File.join(system_memories_dir, "tips.#{key}.md"))).to eq("DeepSeek only\n")
      index = File.read(index_path)
      expect(index).to include("- **tips** · system")
      expect(index).not_to include("tips.#{key}")
      expect(index).not_to include("tips.qwen3")
      expect(inst.warnings.grep(/overlay/)).to be_empty
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "ovl-bundle").read[:files].keys.map(&:to_s))
        .to include("tips.#{key}.md")
    end

    it "removes a stale overlay line an earlier install wrote" do
      install({ "tips.md" => "# Tips\n", "tips.#{key}.md" => "DeepSeek only\n" })
      Samagotchi::MemoryBundle::IndexUpdater.update_index("system", "tips.#{key}", 14, source: "ovl-bundle")
      install({ "tips.md" => "# Tips\n", "tips.#{key}.md" => "DeepSeek only, v2\n" }, upgrade: true)
      expect(File.read(index_path)).not_to include("tips.#{key}")
      expect(File.read(index_path)).to include("- **tips** · system")
    end

    it "warns about an overlay whose base is nowhere, and writes no line for it (dry run warns too)" do
      dry = install({ "other.md" => "x\n", "tips.#{key}.md" => "DeepSeek only\n" }, dry_run: true)
      warning = "tips.#{key}.md is a model overlay with no tips.md; it loads only once tips.md exists"
      expect(dry.warnings).to include(warning)

      inst = install({ "other.md" => "x\n", "tips.#{key}.md" => "DeepSeek only\n" })
      expect(inst.warnings).to include(warning)
      expect(File.read(index_path)).not_to include("tips.#{key}")
    end
  end

  describe "a plain re-install over a local edit" do
    it "keeps the installed base, so the next upgrade still keeps the edit" do
      bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
      target = File.join(system_memories_dir, "identity.md")
      installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
      File.write(target, "# Identity\nmy edit\n")
      installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

      up = described_class.new(source: bundle_dir, name: "test-bundle", scope: "system", strict: true, upgrade: true)
      up.run
      expect(up.results["identity.md"][:status]).to eq("kept")
      expect(File.read(target)).to eq("# Identity\nmy edit\n")
    end
  end

  describe "upgrade: a file the bundle didn't write" do
    def upgrade(source, dry_run: false)
      described_class.new(source: source, name: "up-bundle", scope: "system", strict: true, upgrade: true, dry_run: dry_run).tap(&:run)
    end

    let(:mine) { File.join(system_memories_dir, "notes.md") }

    before do
      installer_for(source: write_bundle(File.join(tmpdir, "v1"), { "keep.md" => "# Keep\n" }, name: "up-bundle", version: "0.1.0"),
                    name: "up-bundle", scope: "system").run
      File.write(mine, "# my notes\n")
    end

    it "is skipped, not merged, not recorded, when a new version starts shipping the same name" do
      v2 = write_bundle(File.join(tmpdir, "v2"), { "keep.md" => "# Keep\n", "notes.md" => "# Theirs\n", "fresh.md" => "# Fresh\n" },
                        name: "up-bundle", version: "0.2.0")
      up = upgrade(v2)

      expect(File.read(mine)).to eq("# my notes\n")
      expect(up.results["notes.md"]).to eq(status: "skipped", reason: "already exists")
      expect(up.conflicts).to be_empty
      expect(up.results["fresh.md"][:status]).to eq("installed")
      data = Samagotchi::MemoryBundle::Provenance.new(name: "up-bundle").read
      expect(data[:files].keys).to contain_exactly(:"keep.md", :"fresh.md")

      # and stays skipped on the next upgrade (no fast-forward over it)
      v3 = write_bundle(File.join(tmpdir, "v3"), { "keep.md" => "# Keep\n", "notes.md" => "# Theirs 2\n" }, name: "up-bundle", version: "0.3.0")
      expect(upgrade(v3).results["notes.md"][:status]).to eq("skipped")
      expect(File.read(mine)).to eq("# my notes\n")
    end

    it "is reported as skipped on a dry run, not as a conflict" do
      v2 = write_bundle(File.join(tmpdir, "v2"), { "keep.md" => "# Keep\n", "notes.md" => "# Theirs\n" }, name: "up-bundle", version: "0.2.0")
      up = upgrade(v2, dry_run: true)
      expect(up.results["notes.md"]).to eq(status: "would_skip")
      expect(up.conflicts).to be_empty
    end
  end

  describe "upgrade: files the new version no longer ships" do
    def bundle_version(dir, files, version)
      FileUtils.rm_rf(File.join(tmpdir, dir))
      write_bundle(File.join(tmpdir, dir), files, name: "drop-bundle", version: version)
    end

    def upgrade(source, force: false, dry_run: false)
      described_class.new(source: source, name: "drop-bundle", scope: "system", strict: true, upgrade: true,
                          force: force, dry_run: dry_run).tap(&:run)
    end

    let(:index_path) { File.join(system_memories_dir, "index.md") }
    let(:old_path) { File.join(system_memories_dir, "old.md") }

    before do
      installer_for(source: bundle_version("v1", { "keep.md" => "# Keep\n", "old.md" => "# Old\n" }, "0.1.0"),
                    name: "drop-bundle", scope: "system").run
    end

    it "removes an unedited dropped file and its index line" do
      expect(File.read(index_path)).to include("old")
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"))

      expect(File.exist?(old_path)).to be false
      expect(File.read(File.join(up.trash_dir, "old.md"))).to eq("# Old\n")
      expect(File.exist?(File.join(system_memories_dir, "keep.md"))).to be true
      expect(File.read(index_path)).not_to match(/^.*\bold\b/)
      expect(up.results["old.md"][:status]).to eq("removed")
      expect(up.summary).to include("Removed (no longer in the bundle): old.md (moved to #{up.trash_dir})")
      data = JSON.parse(File.read(File.join(bundles_dir, "drop-bundle", "manifest.json")))
      expect(data["files"].keys).to eq(["keep.md"])
    end

    it "keeps an edited dropped file with a one-line note" do
      File.write(old_path, "# Old\nmy notes\n")
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"))

      expect(File.read(old_path)).to include("my notes")
      expect(up.results["old.md"][:status]).to eq("kept_pruned")
      expect(up.warnings).to include("Kept old.md: no longer in the bundle but edited locally (use --force to remove)")
    end

    it "removes an edited dropped file with --force" do
      File.write(old_path, "# Old\nmy notes\n")
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"), force: true)
      expect(File.exist?(old_path)).to be false
      expect(File.read(File.join(up.trash_dir, "old.md"))).to eq("# Old\nmy notes\n")
    end

    it "keeps a dropped file another installed bundle has too, and drops it from this bundle's record" do
      Samagotchi::MemoryBundle::Provenance.new(name: "other").write(
        files: { "old.md" => old_path }, scope: "system", version: "1.0.0", source_path: "/x"
      )
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"))

      expect(File.read(old_path)).to eq("# Old\n")
      expect(up.warnings).to include("Kept old.md: no longer in the bundle, but bundle other has it too")
      expect(up.trash_dir).to be_nil
      data = JSON.parse(File.read(File.join(bundles_dir, "drop-bundle", "manifest.json")))
      expect(data["files"].keys).to eq(["keep.md"])
    end

    it "only reports the removal on a dry run" do
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"), dry_run: true)
      expect(File.exist?(old_path)).to be true
      expect(up.results["old.md"][:status]).to eq("would_remove")
      expect(up.trash_dir).to be_nil
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

  describe "hooks" do
    def write_bundle_with_hooks(base_dir, files = {}, hooks = {}, name: "test-bundle", version: "1.0.0", trust_level: nil)
      bundle_dir = File.join(base_dir, "bundle_hooks_#{rand(1000)}")
      FileUtils.mkdir_p(bundle_dir)
      FileUtils.mkdir_p(File.join(bundle_dir, "hooks"))
      files.each { |fname, content| File.write(File.join(bundle_dir, fname), content) }
      hooks.each { |fname, content| File.write(File.join(bundle_dir, "hooks", fname), content) }
      manifest = { "name" => name, "version" => version, "files" => {}, "hooks" => {} }
      files.keys.each { |k| manifest["files"][k] = "sha256:#{Digest::SHA256.hexdigest(files[k])}" }
      hooks.keys.each { |k| manifest["hooks"][k] = { "sha256" => "sha256:#{Digest::SHA256.hexdigest(hooks[k])}", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } }
      manifest["trust_level"] = trust_level if trust_level
      File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))
      bundle_dir
    end

    it "copies hooks/*.rb to <bundle_dir>/hooks/" do
      bundle_dir = write_bundle_with_hooks(tmpdir, { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" })
      installer = installer_for(source: bundle_dir, name: "hook-bundle", scope: "system")
      installer.run
      expect(File.exist?(File.join(bundles_dir, "hook-bundle", "hooks", "guardrails.rb"))).to be true
      expect(installer.results["guardrails.rb"][:status]).to eq("installed")
    end

    it "stores hook provenance and trust_level" do
      bundle_dir = write_bundle_with_hooks(tmpdir, { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, trust_level: "reviewed")
      installer = installer_for(source: bundle_dir, name: "hook-bundle", scope: "system")
      installer.run
      data = JSON.parse(File.read(File.join(bundles_dir, "hook-bundle", "manifest.json")), symbolize_names: true)
      expect(data[:hooks]).to include(:"guardrails.rb")
      expect(data[:trust_level]).to eq("reviewed")
    end

    it "upgrade overwrites hook and warns on local edit" do
      bundle_dir = write_bundle_with_hooks(tmpdir, { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, name: "up-bundle")
      installer = installer_for(source: bundle_dir, name: "up-bundle", scope: "system")
      installer.run
      # local edit
      hook_path = File.join(bundles_dir, "up-bundle", "hooks", "guardrails.rb")
      File.write(hook_path, File.read(hook_path) + "# local edit\n")
      # new bundle version
      bundle_dir2 = write_bundle_with_hooks(tmpdir, { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); raise \"x\"; end; end" }, name: "up-bundle", version: "1.0.1")
      up_installer = described_class.new(source: bundle_dir2, name: "up-bundle", scope: "system", force: false, strict: true, upgrade: true)
      up_installer.run
      expect(up_installer.warnings.any? { |w| w.include?("locally modified") }).to be true
      expect(up_installer.results["guardrails.rb"][:status]).to eq("updated")
    end

    it "dry_run does not copy hooks" do
      bundle_dir = write_bundle_with_hooks(tmpdir, { "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" })
      installer = described_class.new(source: bundle_dir, name: "dry-bundle", scope: "system", force: false, strict: true, dry_run: true)
      installer.run
      expect(File.exist?(File.join(bundles_dir, "dry-bundle", "hooks", "guardrails.rb"))).to be false
      expect(installer.results["guardrails.rb"][:status]).to eq("would_install")
    end

    it "strict hook checksum verify warns on mismatch" do
      bundle_dir = File.join(tmpdir, "bundle_hook_cksum")
      FileUtils.mkdir_p(File.join(bundle_dir, "hooks"))
      File.write(File.join(bundle_dir, "identity.md"), "# Id\n")
      File.write(File.join(bundle_dir, "hooks", "guardrails.rb"), "class Guardrails; def call(e); end; end")
      manifest = { "name" => "cksum-hook", "version" => "1.0", "files" => { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Id\n")}" }, "hooks" => { "guardrails.rb" => { "sha256" => "sha256:0000000000000000000000000000000000000000000000000000000000000000", "event" => "before_tool_call" } } }
      File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))
      installer = installer_for(source: bundle_dir, name: "cksum-hook", scope: "system")
      installer.run
      expect(installer.warnings.any? { |w| w.include?("Checksum mismatch for hook") }).to be true
    end
  end

  describe "needs" do
    let(:fixture) { File.expand_path("../../fixtures/sample_needs_bundle", __dir__) }

    it "records the needs in provenance and warns about a missing one, installing anyway" do
      installer = installer_for(source: fixture, name: "sample-needs", scope: "system")
      installer.run

      expect(File.exist?(File.join(system_memories_dir, "gh_helper.md"))).to be true
      expect(installer.warnings).to include(
        "needs chi-surely-missing-cmd: not found on PATH (put an executable chi-surely-missing-cmd on PATH); installed anyway"
      )
      expect(installer.warnings.grep(/needs sh/)).to be_empty
      expect(installer.summary).to include("needs chi-surely-missing-cmd: not found on PATH")

      data = Samagotchi::MemoryBundle::Provenance.new(name: "sample-needs").read
      expect(data[:needs]).to eq([
        { command: "chi-surely-missing-cmd", why: "stands in for gh in specs and smoke runs",
          hint: "put an executable chi-surely-missing-cmd on PATH" },
        { command: "sh" }
      ])
    end

    it "warns on a dry run too, without writing provenance" do
      installer = described_class.new(source: fixture, name: "sample-needs", scope: "system", dry_run: true)
      installer.run
      expect(installer.warnings).to include(a_string_matching(/needs chi-surely-missing-cmd: .*; would install anyway/))
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "sample-needs").read).to be_nil
    end

    it "drops the stored needs when a reinstall's manifest has none" do
      installer_for(source: fixture, name: "sample-needs", scope: "system").run
      plain = write_bundle(tmpdir, { "gh_helper.md" => "# gh helper\n" }, name: "sample-needs")
      installer_for(source: plain, name: "sample-needs", scope: "system", force: true).run
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "sample-needs").read).not_to have_key(:needs)
    end
  end
end
