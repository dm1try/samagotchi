# frozen_string_literal: true

require "spec_helper"
require "support/legacy_hooks_record"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "digest"

require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/status"

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

  def set_requires_chi(bundle_dir, constraint)
    path = File.join(bundle_dir, "manifest.yml")
    manifest = YAML.safe_load_file(path)
    manifest["requires_chi"] = constraint
    File.write(path, YAML.dump(manifest))
  end

  describe "#run" do
    context "with a directory source" do
      it "keeps the bundle's manifest.yml, recorded by its sha; a dry run keeps nothing" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
        kept = File.join(bundles_dir, "test-bundle", "manifest.yml")
        described_class.new(source: bundle_dir, name: "test-bundle", strict: true, dry_run: true).run
        expect(File.exist?(kept)).to be(false)

        installer_for(source: bundle_dir, name: "test-bundle").run
        expect(File.read(kept)).to eq(File.read(File.join(bundle_dir, "manifest.yml")))
        record = JSON.parse(File.read(File.join(bundles_dir, "test-bundle", "manifest.json")))
        expect(record).to include("manifest_sha" => "sha256:#{Digest::SHA256.file(kept).hexdigest}",
                                  "installed_by" => Samagotchi::VERSION)
      end

      it "installs .md files into the system scope directory" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n",
          "commit_preferences.md" => "# Preferences\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
        expect(File.read(File.join(system_memories_dir, "identity.md"))).to eq("# Identity\n")
        expect(installer.results["identity.md"].word).to eq(:installed)
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

        expect(installer.results["identity.md"].word).to eq(:kept_own)
        expect(installer.results["new_file.md"].word).to eq(:installed)
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

        expect(installer.results["identity.md"].word).to eq(:up_to_date)
        expect(installer.warnings).to be_empty
        expect(installer.summary).not_to include("--force")
      end

      it "re-installing an installed bundle says what it rewrote, once" do
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

        again = installer_for(source: bundle_dir, name: "test-bundle", scope: "system")
        again.run
        line = "test-bundle was already installed from #{bundle_dir}: its rules, plugin and scripts " \
               "now match it and its record was rewritten"
        expect(again.summary.lines.map(&:chomp).count(line)).to eq(1)
        expect(again.summary).to include("Up to date: identity.md")
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
        expect(again.results["identity.md"].word).to eq(:kept_own)
        expect(again.warnings).to eq(["Skipped identity.md (already exists; #{Samagotchi::MemoryBundle::FileStanding::FORCE_TAKES})"])
        expect(again.summary).to include("chi bundle upgrade test-bundle")
      end

      # D4 (P5): a source that moved on gives its new text to a memory never edited.
      it "takes a moved-on source's text for a file never edited, and keeps an edited one" do
        bundle_dir = write_bundle(tmpdir, { "plain.md" => "# Plain\n", "mine.md" => "# Mine\n" })
        installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run
        File.write(File.join(system_memories_dir, "mine.md"), "# Mine, edited\n")
        write_bundle(tmpdir, { "plain.md" => "# Plain v2\n", "mine.md" => "# Mine v2\n" }, version: "2.0.0")

        dry = described_class.new(source: bundle_dir, name: "test-bundle", scope: "system", strict: true, dry_run: true).tap(&:run)
        again = installer_for(source: bundle_dir, name: "test-bundle", scope: "system").tap(&:run)

        expect(dry.summary).to include("Fast-forward: plain.md").and include("Skipped: mine.md")
        expect(again.summary).to include("Updated: plain.md").and include("Skipped: mine.md")
        # write_bundle's sha is fake: the fast-forward of plain.md is checked (U7).
        expect(again.warnings.grep(/Checksum mismatch/)).to eq(["Checksum mismatch for plain.md: expected fake..., got #{Digest::SHA256.hexdigest("# Plain v2\n")[0..7]}..."])
        expect(again.warnings.grep_v(/Checksum mismatch/)).to eq(["Skipped mine.md (already exists; #{Samagotchi::MemoryBundle::FileStanding::FORCE_TAKES})"])
        expect(File.read(File.join(system_memories_dir, "plain.md"))).to eq("# Plain v2\n")
        expect(File.read(File.join(system_memories_dir, "mine.md"))).to eq("# Mine, edited\n")
        provenance = Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle")
        expect(provenance.record.version).to eq("2.0.0")
        expect(File.read(provenance.base_path("plain.md"))).to eq("# Plain v2\n")
        status = Samagotchi::MemoryBundle::Status.bundle_status("test-bundle")
        expect(status.files["plain.md"]).to include(modified: false, missing: false, behind: nil)
      end

      it "a dry run reports an identical file as already up to date" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Identity\n")
        bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })

        installer = described_class.new(source: bundle_dir, name: "test-bundle", scope: "system", strict: true, dry_run: true)
        installer.run
        expect(installer.results["identity.md"].word).to eq(:up_to_date)
      end

      it "overwrites existing files with --force" do
        FileUtils.mkdir_p(system_memories_dir)
        File.write(File.join(system_memories_dir, "identity.md"), "# Old\n")

        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# New Identity\n"
        })

        installer = installer_for(source: bundle_dir, name: "test-bundle", scope: "system", force: true)
        installer.run

        expect(installer.results["identity.md"].word).to eq(:installed)
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

        it "writes a file's manifest description into its index line and its record" do
          bundle_dir = write_bundle(tmpdir, { "skill_x.md" => "# Skill: x\n", "identity.md" => "# Identity\n" })
          manifest = YAML.safe_load_file(File.join(bundle_dir, "manifest.yml"))
          manifest["files"]["skill_x.md"] = { "sha256" => "sha256:fake", "description" => "Use when x" }
          File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))

          installer_for(source: bundle_dir, name: "test-bundle", scope: "system").run

          index_content = File.read(File.join(system_memories_dir, "index.md"))
          expect(index_content).to include("- **skill_x** · system · #{Date.today.iso8601} · 11 · from test-bundle — Use when x\n")
          expect(index_content).to include("- **identity** · system · #{Date.today.iso8601} · 11 · from test-bundle\n")
          record = Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle").read
          expect(record[:files][:"skill_x.md"]).to include(description: "Use when x")
          expect(record[:files][:"identity.md"]).not_to have_key(:description)
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

        it "skips memory checksum warnings for a dev install, but not a regular install" do
          dev_source = write_bundle(File.join(tmpdir, "dev"), { "identity.md" => "# Identity\n" }, name: "dev-check")
          regular_source = write_bundle(File.join(tmpdir, "regular"), { "regular.md" => "# Regular\n" }, name: "regular-check")
          dev = described_class.new(source: dev_source, name: "dev-check", scope: "system", strict: true, dev: true).tap(&:run)
          regular = described_class.new(source: regular_source, name: "regular-check", scope: "system", strict: true).tap(&:run)

          expect(dev.warnings.grep(/Checksum mismatch/)).to be_empty
          expect(regular.warnings.grep(/Checksum mismatch/)).to include("Checksum mismatch for regular.md: expected fake..., got #{Digest::SHA256.hexdigest("# Regular\n")[0..7]}...")
        end

        it "checks a --force install over a file that already has the bundle's text, and its dry run" do
          bundle_dir = File.join(tmpdir, "bundle_checksum_forced")
          FileUtils.mkdir_p(bundle_dir)
          File.write(File.join(bundle_dir, "identity.md"), "# Identity\n")
          FileUtils.mkdir_p(system_memories_dir)
          File.write(File.join(system_memories_dir, "identity.md"), "# Identity\n")
          File.write(File.join(bundle_dir, "manifest.yml"),
                     YAML.dump("name" => "cksum-forced", "version" => "1.0", "files" => { "identity.md" => "sha256:#{"0" * 64}" }))

          dry = described_class.new(source: bundle_dir, name: "cksum-forced", scope: "system", strict: true, force: true, dry_run: true)
          dry.run
          installer = installer_for(source: bundle_dir, name: "cksum-forced", scope: "system", force: true)
          installer.run

          expect(dry.warnings.grep(/Checksum mismatch for identity\.md/).size).to eq(1)
          expect(installer.warnings.grep(/Checksum mismatch for identity\.md/).size).to eq(1)
          expect(installer.summary).to include("Installed: identity.md")
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

        it "does not warn when a files entry declares no checksum" do
          bundle_dir = File.join(tmpdir, "bundle_cksum_none")
          FileUtils.mkdir_p(bundle_dir)
          File.write(File.join(bundle_dir, "identity.md"), "# Identity\n")
          # A description-only entry: no sha256 at all.
          manifest = { "name" => "cksum-none", "version" => "1.0", "files" => {
            "identity.md" => { "description" => "Who this bundle is for" }
          } }
          File.write(File.join(bundle_dir, "manifest.yml"), YAML.dump(manifest))

          installer = installer_for(source: bundle_dir, name: "cksum-none", scope: "system")
          installer.run

          checksum_warnings = installer.warnings.select { |w| w.include?("Checksum mismatch") }
          expect(checksum_warnings).to be_empty
        end

        it "checks a memory an upgrade or a re-install fast-forwards, and its dry run (U7)" do
          bundle = lambda do |dir, version, text, sha|
            FileUtils.mkdir_p(dir)
            File.write(File.join(dir, "identity.md"), text)
            File.write(File.join(dir, "manifest.yml"),
                       YAML.dump("name" => "cksum-ff", "version" => version, "files" => { "identity.md" => "sha256:#{sha}" }))
            dir
          end
          v1 = bundle.call(File.join(tmpdir, "ff", "1"), "1.0", "# Identity\n", Digest::SHA256.hexdigest("# Identity\n"))
          v2 = bundle.call(File.join(tmpdir, "ff", "2"), "2.0", "# Identity v2\n", "0" * 64)
          installer_for(source: v1, name: "cksum-ff", scope: "system").run

          dry = described_class.new(source: v2, name: "cksum-ff", scope: "system", strict: true, upgrade: true, dry_run: true)
          dry.run
          up = described_class.new(source: v2, name: "cksum-ff", scope: "system", strict: true, upgrade: true)
          up.run

          expect(dry.warnings.grep(/Checksum mismatch for identity\.md/).size).to eq(1)
          expect(up.summary).to include("Updated: identity.md")
          expect(up.warnings.grep(/Checksum mismatch for identity\.md/).size).to eq(1)

          # A plain re-install from the same source, moved on (D4).
          bundle.call(v2, "3.0", "# Identity v3\n", "0" * 64)
          again = installer_for(source: v2, name: "cksum-ff", scope: "system")
          again.run
          expect(again.summary).to include("Updated: identity.md")
          expect(again.warnings.grep(/Checksum mismatch for identity\.md/).size).to eq(1)
        end

        # A dry run checks the bytes it would write, not the user's edit on disk.
        it "does not blame an edited file on a --force dry run whose source matches its sha" do
          bundle_dir = File.join(tmpdir, "bundle_cksum_edit")
          FileUtils.mkdir_p(bundle_dir)
          File.write(File.join(bundle_dir, "identity.md"), "# Identity\n")
          File.write(File.join(bundle_dir, "manifest.yml"),
                     YAML.dump("name" => "cksum-edit", "version" => "1.0",
                               "files" => { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Identity\n")}" }))
          installer_for(source: bundle_dir, name: "cksum-edit", scope: "system").run
          File.write(File.join(system_memories_dir, "identity.md"), "# Identity, mine\n")

          dry = described_class.new(source: bundle_dir, name: "cksum-edit", scope: "system", strict: true, force: true, dry_run: true)
          dry.run

          expect(dry.summary).to include("identity.md")
          expect(dry.warnings.grep(/Checksum mismatch/)).to be_empty
        end

        it "checks the bundle's file an upgrade merges into a local edit" do
          dir = File.join(tmpdir, "bundle_cksum_merge")
          FileUtils.mkdir_p(dir)
          write = lambda do |version, text, sha|
            File.write(File.join(dir, "a.md"), text)
            File.write(File.join(dir, "manifest.yml"),
                       YAML.dump("name" => "cksum-merge", "version" => version, "files" => { "a.md" => "sha256:#{sha}" }))
          end
          write.call("1.0", "a\nb\nc\n", Digest::SHA256.hexdigest("a\nb\nc\n"))
          installer_for(source: dir, name: "cksum-merge", scope: "system").run
          File.write(File.join(system_memories_dir, "a.md"), "A\nb\nc\n")
          write.call("2.0", "a\nb\nC\n", "0" * 64)

          up = described_class.new(source: dir, name: "cksum-merge", scope: "system", strict: true, upgrade: true)
          up.run

          expect(up.merged_files).to eq(["a.md"])
          expect(File.read(File.join(system_memories_dir, "a.md"))).to eq("A\nb\nC\n")
          expect(up.warnings.grep(/Checksum mismatch for a\.md/).size).to eq(1)
        end
      end
    end

    context "with a zip source" do
      it "extracts and installs from a zip file" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })

        zip_path = File.join(tmpdir, "bundle.zip")
        system("zip", "-r", zip_path, ".", chdir: bundle_dir)

        installer = installer_for(source: zip_path, name: "zip-bundle", scope: "system")
        installer.run

        expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be true
      end

      it "cleans up temp dir after zip install (P1)" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })
        zip_path = File.join(tmpdir, "bundle.zip")
        system("zip", "-r", zip_path, ".", chdir: bundle_dir)

        normalized = nil
        allow(Samagotchi::MemoryBundle::SourceNormalizer).to receive(:normalize).and_wrap_original do |original, *args|
          original.call(*args).tap { |result| normalized = result.first }
        end
        installer = installer_for(source: zip_path, name: "zip-bundle", scope: "system")
        installer.run

        # The copy extracted from the zip is the installer's to remove.
        expect(normalized).to start_with(Dir.tmpdir)
        expect(File.exist?(normalized)).to be(false)
      end
    end

    context "with a tar.gz source" do
      it "extracts and installs from a tar.gz file" do
        bundle_dir = write_bundle(tmpdir, {
          "identity.md" => "# Identity\n"
        })

        tar_path = File.join(tmpdir, "bundle.tar.gz")
        system("tar", "-czf", tar_path, File.basename(bundle_dir), chdir: tmpdir)

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

  # A bundle's own specs (lib/samagotchi/bundles/<name>/spec/, the bundle
  # test kit's) stay in its source: nothing under spec/ is installed.
  it "installs nothing from the bundle's spec/ folder" do
    bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
    FileUtils.mkdir_p(File.join(bundle_dir, "spec", "fixtures"))
    File.write(File.join(bundle_dir, "spec", "test_bundle_spec.rb"), "# a spec\n")
    File.write(File.join(bundle_dir, "spec", "fixtures", "notes.md"), "# a fixture\n")

    installer_for(source: bundle_dir, name: "test-bundle").run

    installed = Dir.glob("**/*", base: File.join(tmpdir, "config"))
    expect(installed).to include(a_string_ending_with("identity.md"))
    expect(installed.grep(/spec|notes\.md|fixtures/)).to eq([])
  end

  describe "a manifest key this chi doesn't read" do
    def bundle_with(base, extra)
      dir = write_bundle(File.join(tmpdir, base), { "identity.md" => "# Identity\n" }, name: "future-bundle")
      path = File.join(dir, "manifest.yml")
      File.write(path, YAML.dump(YAML.safe_load_file(path).merge(extra)))
      dir
    end

    def warning(key)
      Samagotchi::MemoryBundle::Manifest.unknown_key_line(key) +
        "; a newer chi reads it from the installed manifest (chi update, then chi bundle status future-bundle " \
        "says whether it needs chi bundle upgrade future-bundle)"
    end

    it "warns once per unknown key, in a dry run too, and not for a manifest of keys chi knows" do
      dir = bundle_with("future", { "card_layouts" => %w[cards panels], "api_version" => 3 })
      expected = [warning("card_layouts"), warning("api_version")]

      dry = described_class.new(source: dir, name: "future-bundle", scope: "system", strict: true, dry_run: true).tap(&:run)
      expect(dry.warnings.grep(/doesn't know/)).to eq(expected)

      installer = installer_for(source: dir, name: "future-bundle", scope: "system")
      installer.run
      expect(installer.warnings.grep(/doesn't know/)).to eq(expected)

      clean = write_bundle(File.join(tmpdir, "clean"), { "identity.md" => "# Identity\n" }, name: "clean-bundle")
      expect(installer_for(source: clean, name: "clean-bundle", scope: "system").tap(&:run).warnings.grep(/doesn't know/)).to eq([])
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
      expect(up.results["guardrails/a.yml"].word).to eq(:up_to_date)
      expect(up.results["guardrails/b.yml"].word).to eq(:installed)
      expect(File.read(File.join(bundles_dir, "test-bundle", "guardrails", "b.yml"))).to eq("rules: [] # v2\n")
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "test-bundle").read[:guardrails].keys.map(&:to_s))
        .to contain_exactly("a.yml", "b.yml")
    end

    # GuardrailWiring#bundle_rules won't read them, and a session that never
    # loaded them refuses guarded calls until chi is updated: say so here.
    # Such a bundle is refused unless --force, so these installs force it.
    it "warns that its rules won't load when this chi doesn't meet requires_chi" do
      bundle_dir = write_bundle(tmpdir, { "identity.md" => "# Identity\n" })
      FileUtils.mkdir_p(File.join(bundle_dir, "guardrails"))
      File.write(File.join(bundle_dir, "guardrails", "a.yml"), "rules: []\n")
      set_requires_chi(bundle_dir, ">= 99.0")

      installer = installer_for(source: bundle_dir, name: "rules-bundle", scope: "system", force: true)
      installer.run

      expect(installer.warnings).to include(
        "Bundle rules-bundle: its guardrail rules won't load: it requires chi >= 99.0 " \
        "(this is chi #{Samagotchi::VERSION}); until chi is updated (chi update), guarded tool calls are refused"
      )
    end

    it "doesn't warn about the rules when this chi meets requires_chi or the bundle ships none" do
      with_rules = write_bundle(File.join(tmpdir, "rules"), { "identity.md" => "# Identity\n" }, name: "rules-bundle")
      FileUtils.mkdir_p(File.join(with_rules, "guardrails"))
      File.write(File.join(with_rules, "guardrails", "a.yml"), "rules: []\n")
      set_requires_chi(with_rules, ">= 0.1.0")
      with_rules_installer = installer_for(source: with_rules, name: "rules-bundle", scope: "system")
      with_rules_installer.run

      plain = write_bundle(File.join(tmpdir, "plain"), { "identity.md" => "# Identity\n" }, name: "plain-bundle")
      set_requires_chi(plain, ">= 99.0")
      plain_installer = installer_for(source: plain, name: "plain-bundle", scope: "system", force: true)
      plain_installer.run

      expect(with_rules_installer.warnings.join).not_to include("guardrail rules")
      expect(plain_installer.warnings.join).not_to include("guardrail rules")
    end
  end

  # A bundle this chi is too old for is not installed at all: --force is what
  # installs it, and then its plugin, hooks and rules warn as they don't load.
  describe "requires_chi this chi doesn't meet" do
    def rules_bundle(base, name: "newer", version: "1.0.0", requires_chi: ">= 99.0")
      bundle_dir = write_bundle(File.join(tmpdir, base), { "identity.md" => "# Identity\n" }, name: name, version: version)
      FileUtils.mkdir_p(File.join(bundle_dir, "guardrails"))
      File.write(File.join(bundle_dir, "guardrails", "a.yml"), "rules: []\n")
      set_requires_chi(bundle_dir, requires_chi) if requires_chi
      bundle_dir
    end

    def refusal(name, requirement)
      "#{name} can't be installed: it requires chi #{requirement} (this is chi #{Samagotchi::VERSION}) " \
        "(chi update, or --force to install it anyway)"
    end

    it "refuses it, writing nothing to the scope dir or under .bundles/" do
      bundle_dir = rules_bundle("too-new")

      expect { installer_for(source: bundle_dir, name: "newer", scope: "system").run }
        .to raise_error(described_class::InstallError, refusal("newer", ">= 99.0"))

      expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be(false)
      expect(Dir.exist?(File.join(bundles_dir, "newer"))).to be(false)
      expect(Dir.glob(File.join(system_memories_dir, "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }).to eq([])
    end

    it "refuses a dry run the same way" do
      bundle_dir = rules_bundle("too-new-dry")
      dry = described_class.new(source: bundle_dir, name: "newer", scope: "system", strict: true, dry_run: true)

      expect { dry.run }.to raise_error(described_class::InstallError, refusal("newer", ">= 99.0"))
      expect(Dir.exist?(File.join(bundles_dir, "newer"))).to be(false)
    end

    it "installs with force:, warnings and all" do
      bundle_dir = rules_bundle("too-new-force")
      installer = installer_for(source: bundle_dir, name: "newer", scope: "system", force: true)
      installer.run

      expect(installer.warnings).to include(
        "Bundle newer: its guardrail rules won't load: it requires chi >= 99.0 (this is chi #{Samagotchi::VERSION}); " \
        "until chi is updated (chi update), guarded tool calls are refused"
      )
      expect(File.exist?(File.join(bundles_dir, "newer", "guardrails", "a.yml"))).to be(true)
    end

    it "refuses an upgrade to a version this chi is too old for, keeping the installed one" do
      v1 = rules_bundle("v1", requires_chi: nil)
      installer_for(source: v1, name: "newer", scope: "system").run
      v2 = rules_bundle("v2", version: "2.0.0", requires_chi: ">= 99.0")

      expect { described_class.new(source: v2, name: "newer", scope: "system", strict: true, upgrade: true).run }
        .to raise_error(described_class::InstallError, refusal("newer", ">= 99.0"))
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "newer").read[:version]).to eq("1.0.0")

      forced = described_class.new(source: v2, name: "newer", scope: "system", strict: true, upgrade: true, force: true)
      forced.run
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "newer").read[:version]).to eq("2.0.0")
    end

    it "refuses a dry-run upgrade of a too-new version too" do
      v1 = rules_bundle("v1-dry", requires_chi: nil)
      installer_for(source: v1, name: "newer", scope: "system").run
      v2 = rules_bundle("v2-dry", version: "2.0.0", requires_chi: ">= 99.0")

      expect { described_class.new(source: v2, name: "newer", scope: "system", strict: true, upgrade: true, dry_run: true).run }
        .to raise_error(described_class::InstallError, refusal("newer", ">= 99.0"))
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

    it "takes a file whose base is only among the installed memories as an overlay of it, and says so" do
      FileUtils.mkdir_p(system_memories_dir)
      File.write(File.join(system_memories_dir, "tips.md"), "my own tips\n")
      inst = install({ "tips.#{key}.md" => "DeepSeek only\n" })
      expect(inst.warnings).to include("tips.#{key}.md is taken as a model overlay of your tips.md, which the bundle " \
                                       "doesn't ship; it gets no index line")
      expect(File.exist?(index_path) ? File.read(index_path) : "").not_to include("tips.#{key}")
      expect(Samagotchi::MemoryBundle::Status.bundle_status("ovl-bundle").files["tips.#{key}.md"][:overlay]).to be(true)
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
      expect(up.results["identity.md"].word).to eq(:kept)
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
      expect(up.results["notes.md"].word).to eq(:kept_own)
      expect(up.conflicts).to be_empty
      expect(up.results["fresh.md"].word).to eq(:installed)
      data = Samagotchi::MemoryBundle::Provenance.new(name: "up-bundle").read
      expect(data[:files].keys).to contain_exactly(:"keep.md", :"fresh.md")

      # and stays skipped on the next upgrade (no fast-forward over it)
      v3 = write_bundle(File.join(tmpdir, "v3"), { "keep.md" => "# Keep\n", "notes.md" => "# Theirs 2\n" }, name: "up-bundle", version: "0.3.0")
      expect(upgrade(v3).results["notes.md"].word).to eq(:kept_own)
      expect(File.read(mine)).to eq("# my notes\n")
    end

    it "is reported as skipped on a dry run, not as a conflict" do
      v2 = write_bundle(File.join(tmpdir, "v2"), { "keep.md" => "# Keep\n", "notes.md" => "# Theirs\n" }, name: "up-bundle", version: "0.2.0")
      up = upgrade(v2, dry_run: true)
      expect(up.results["notes.md"].word).to eq(:would_skip)
      expect(up.conflicts).to be_empty
    end
  end

  # BundleCommand normalizes the source once (a git clone, a zip or tar
  # extract) to read the bundle's name, and hands that to the Installer.
  describe "a prepared source" do
    it "installs from it without normalizing the source again, and removes an owned one after the run" do
      bundle = write_bundle(File.join(tmpdir, "p"), { "a.md" => "one\n" }, name: "prepped")
      extract = File.join(tmpdir, "extract")
      FileUtils.cp_r(bundle, extract)
      prepared = Samagotchi::MemoryBundle::PreparedSource.new(dir: extract, owned: true, commit: "abc123")
      allow(Samagotchi::MemoryBundle::SourceNormalizer).to receive(:normalize).and_raise("normalized again")

      described_class.new(source: "https://example.com/prepped.git", name: "prepped", strict: true, prepared: prepared).run

      expect(Samagotchi::MemoryBundle::SourceNormalizer).not_to have_received(:normalize)
      expect(File.read(File.join(system_memories_dir, "a.md"))).to eq("one\n")
      record = JSON.parse(File.read(File.join(bundles_dir, "prepped", "manifest.json")))
      expect(record.values_at("source", "source_commit")).to eq(["https://example.com/prepped.git", "abc123"])
      expect(Dir.exist?(extract)).to be(false)
    end
  end

  describe "an upgrade from an owned source (zip) with a conflict" do
    # A zip source is extracted to a temp dir the installer owns; the
    # conflict's incoming: path points into it, so it must outlive #run
    # until the agent step is done.
    def zip_of(dir, path)
      FileUtils.rm_f(path)
      system("zip", "-r", path, ".", chdir: dir)
      path
    end

    it "keeps the incoming file readable after run, and cleans up on cleanup_source!" do
      v1 = write_bundle(File.join(tmpdir, "z1"), { "a.md" => "one\n" }, name: "zip-up", version: "1.0.0")
      installer_for(source: v1, name: "zip-up", scope: "system").run
      File.write(File.join(system_memories_dir, "a.md"), "edited\n")

      v2 = write_bundle(File.join(tmpdir, "z2"), { "a.md" => "two\n" }, name: "zip-up", version: "2.0.0")
      zip = zip_of(v2, File.join(tmpdir, "z2.zip"))

      up = described_class.new(source: zip, name: "zip-up", scope: "system", strict: true, upgrade: true)
      up.run

      incoming = up.conflicts["a.md"][:incoming]
      expect(File.exist?(incoming)).to be(true)
      expect(File.read(incoming)).to eq("two\n")

      up.cleanup_source!
      expect(File.exist?(incoming)).to be(false)
      expect(up.source_dir).to be_nil
    end

    it "cleans up right away when there is no conflict" do
      v1 = write_bundle(File.join(tmpdir, "z3"), { "a.md" => "one\n" }, name: "zip-clean", version: "1.0.0")
      installer_for(source: v1, name: "zip-clean", scope: "system").run

      v2 = write_bundle(File.join(tmpdir, "z4"), { "a.md" => "two\n" }, name: "zip-clean", version: "2.0.0")
      zip = zip_of(v2, File.join(tmpdir, "z4.zip"))

      up = described_class.new(source: zip, name: "zip-clean", scope: "system", strict: true, upgrade: true)
      up.run

      expect(up.conflicts).to be_empty
      expect(up.source_dir).to be_nil
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
      expect(up.results["old.md"].word).to eq(:removed)
      expect(up.summary).to include("Removed (no longer in the bundle): old.md (moved to #{up.trash_dir})")
      data = JSON.parse(File.read(File.join(bundles_dir, "drop-bundle", "manifest.json")))
      expect(data["files"].keys).to eq(["keep.md"])
    end

    it "keeps an edited dropped file with a one-line note" do
      File.write(old_path, "# Old\nmy notes\n")
      up = upgrade(bundle_version("v2", { "keep.md" => "# Keep\n" }, "0.1.1"))

      expect(File.read(old_path)).to include("my notes")
      expect(up.results["old.md"].word).to eq(:kept_pruned)
      expect(up.warnings).to include("Kept old.md: no longer in the bundle but edited locally (--force moves it to the trash)")
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
      expect(up.results["old.md"].word).to eq(:would_remove)
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

    # A bundle with one memory and one script, so the summary has both kinds
    # of file to name.
    def summary_bundle(files: { "tips.md" => "# Tips\n" }, scripts: { "g.sh" => "#!/bin/sh\n" })
      dir = File.join(tmpdir, "summary-bundle")
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      files.each { |name, text| File.write(File.join(dir, name), text) }
      scripts.each { |name, text| File.write(File.join(dir, "scripts", name), text) }
      manifest = {
        "name" => "sum-bundle", "version" => "1.0.0", "scope" => "system",
        "files" => files.to_h { |name, text| [name, "sha256:#{Digest::SHA256.hexdigest(text)}"] },
        "scripts" => scripts.to_h { |name, text| [name, "sha256:#{Digest::SHA256.hexdigest(text)}"] }
      }
      File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      dir
    end

    def install_summary(dir)
      described_class.new(source: dir, name: "sum-bundle", scope: "system", strict: true).tap(&:run)
    end

    def rewritten_line(source)
      "sum-bundle was already installed from #{source}: its rules, plugin and scripts " \
        "now match it and its record was rewritten"
    end

    it "a file that already holds the bundle's bytes is Up to date, not Skipped" do
      dir = summary_bundle
      install_summary(dir)
      again = install_summary(dir)

      expect(again.results["tips.md"].word).to eq(:up_to_date)
      expect(again.results["scripts/g.sh"].word).to eq(:up_to_date)
      expect(again.summary).to include("Up to date: tips.md, scripts/g.sh")
      expect(again.summary).not_to include("Skipped:")
    end

    it "a memory the user wrote is still Skipped, and its own bytes are not Up to date" do
      dir = summary_bundle
      install_summary(dir)
      File.write(File.join(system_memories_dir, "tips.md"), "# Mine\n")
      again = install_summary(dir)

      expect(again.summary).to include("Skipped: tips.md")
      expect(again.summary).to include("Up to date: scripts/g.sh")
      expect(again.summary).not_to include("Up to date: tips.md")
    end

    it "a reinstall names what it rewrote, and the memories it kept" do
      dir = summary_bundle
      install_summary(dir)
      File.write(File.join(system_memories_dir, "tips.md"), "# Mine\n")

      expect(install_summary(dir).summary).to include(
        "#{rewritten_line(dir)}; your own copies of its memories were kept " \
        "(chi bundle upgrade sum-bundle merges the bundle's changes into them)"
      )
    end

    it "with no kept memory the reinstall line ends at the rewritten record" do
      dir = summary_bundle
      install_summary(dir)

      expect(install_summary(dir).summary).to end_with(rewritten_line(dir))
    end

    it "a dry run says nothing about reinstalling, since it rewrote nothing" do
      dir = summary_bundle
      install_summary(dir)
      dry = described_class.new(source: dir, name: "sum-bundle", scope: "system", strict: true, dry_run: true).tap(&:run)

      expect(dry.summary).not_to include("was already installed")
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

  describe "class-file hooks (retired)" do
    let(:words) { Samagotchi::MemoryBundle::Manifest::HooksRetired::WORDS }

    def source_with(dir, manifest: {}, files: {})
      FileUtils.mkdir_p(dir)
      { "identity.md" => "# Id\n" }.merge(files).each do |file, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
        File.write(File.join(dir, file), text)
      end
      File.write(File.join(dir, "manifest.yml"), YAML.dump({ "name" => "hb", "version" => "1.0.0", "scope" => "system",
                                                             "files" => { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Id\n")}" } }
                                                             .merge(manifest)))
      dir
    end

    def run(source, **opts) = described_class.new(source: source, name: "hb", scope: "system", **opts).tap(&:run)

    it "refuses a source whose manifest lists hooks, strict or not, its dry run too, and writes nothing" do
      src = source_with(File.join(tmpdir, "listed"), manifest: { "hooks" => { "g.rb" => { "event" => "before_tool_call" } } },
                                                     files: { "hooks/g.rb" => "class G; end\n" })
      [{}, { strict: false }, { dry_run: true }, { force: true }].each do |opts|
        expect { run(src, **opts) }.to raise_error(described_class::InstallError, "hooks/g.rb: #{words}"), opts.inspect
      end
      FileUtils.rm_rf(File.join(src, "hooks"))
      expect { run(src, strict: false) }.to raise_error(described_class::InstallError, "hooks: #{words}")
      expect(Dir.exist?(File.join(bundles_dir, "hb"))).to be(false)
      expect(File.exist?(File.join(system_memories_dir, "identity.md"))).to be(false)
    end

    it "refuses a source with hooks/*.rb and no hooks: key" do
      src = source_with(File.join(tmpdir, "unlisted"), files: { "hooks/a.rb" => "# a\n", "hooks/b.rb" => "# b\n" })
      expect { run(src) }.to raise_error(described_class::InstallError, "hooks/a.rb, hooks/b.rb: #{words}")
    end

    it "takes a source that keeps an empty hooks: key" do
      expect(run(source_with(File.join(tmpdir, "empty-key"), manifest: { "hooks" => {} })).results["identity.md"].word).to eq(:installed)
    end

    describe "an older chi's record that still has them" do
      let(:src) { source_with(File.join(tmpdir, "ported"), manifest: { "version" => "1.1.0" }) }
      let(:bundle_dir) { File.join(bundles_dir, "hb") }

      before do
        run(source_with(File.join(tmpdir, "v1")))
        LegacyHooksRecord.legacy_hooks_record("hb", hooks: { "a.rb" => "# a\n", "b.rb" => "# b\n" }, edited: ["b.rb"])
      end

      it "removes them on an upgrade, the edited one copied to the trash first, and records none" do
        up = run(src, upgrade: true)

        expect(up.results.slice("hooks/a.rb", "hooks/b.rb").values.map(&:word)).to eq(%i[removed removed])
        expect(up.summary).to include("Removed (chi no longer loads class-file bundle hooks): hooks/a.rb, hooks/b.rb\n")
        expect(up.summary).to include("Copied to the trash first: hooks/b.rb (#{up.trash_dir})")
        expect(File.read(File.join(up.trash_dir, "hooks", "b.rb"))).to eq("# edited by hand\n")
        expect(File.exist?(File.join(up.trash_dir, "hooks", "a.rb"))).to be(false)
        expect(Dir.exist?(File.join(bundle_dir, "hooks"))).to be(false)
        expect(Dir.glob(File.join(bundle_dir, "bases", "*.rb"))).to eq([])
        expect(JSON.parse(File.read(File.join(bundle_dir, "manifest.json")))["hooks"]).to eq({})
      end

      it "says the same in a dry run, and changes nothing" do
        dry = run(src, upgrade: true, dry_run: true)

        expect(dry.results.slice("hooks/a.rb", "hooks/b.rb").values.map(&:word)).to eq(%i[would_remove would_remove])
        expect(dry.summary).to include("Would remove (chi no longer loads class-file bundle hooks): hooks/a.rb, hooks/b.rb\n")
        expect(Dir.children(File.join(bundle_dir, "hooks")).sort).to eq(%w[a.rb b.rb])
        expect(JSON.parse(File.read(File.join(bundle_dir, "manifest.json")))["hooks"].keys).to eq(%w[a.rb b.rb])
      end

      it "removes them on a plain install too" do
        run(File.join(tmpdir, "v1"))
        expect(Dir.exist?(File.join(bundle_dir, "hooks"))).to be(false)
      end

      it "leaves them when the install fails on a file the manifest names (the plugin), before it removes anything" do
        broken = source_with(File.join(tmpdir, "broken"), manifest: { "version" => "1.1.0", "plugin" => { "file" => "plugin.rb" } })
        expect { run(broken, upgrade: true) }.to raise_error(described_class::InstallError, /plugin plugin\.rb, which the bundle doesn't have/)
        expect(Dir.children(File.join(bundle_dir, "hooks")).sort).to eq(%w[a.rb b.rb])
      end
    end

    it "removes an empty hooks/ dir without a word" do
      run(source_with(File.join(tmpdir, "v1")))
      FileUtils.mkdir_p(File.join(bundles_dir, "hb", "hooks"))
      up = run(source_with(File.join(tmpdir, "v2"), manifest: { "version" => "1.1.0" }), upgrade: true)
      expect(up.summary).not_to include("hooks")
      expect(Dir.exist?(File.join(bundles_dir, "hb", "hooks"))).to be(false)
    end

    it "removes a dev record's hook links, not their targets, and copies nothing to the trash" do
      dev_src = source_with(File.join(tmpdir, "dev"))
      run(dev_src, dev: true)
      FileUtils.mkdir_p(File.join(tmpdir, "dev-hooks"))
      target = File.join(tmpdir, "dev-hooks", "g.rb").tap { |path| File.write(path, "# the source's hook\n") }
      FileUtils.mkdir_p(File.join(bundles_dir, "hb", "hooks"))
      File.symlink(target, File.join(bundles_dir, "hb", "hooks", "g.rb"))
      LegacyHooksRecord.legacy_hooks_record("hb", hooks: { "g.rb" => { text: nil } })

      again = run(dev_src, dev: true)
      expect(again.summary).to include("Removed (chi no longer loads class-file bundle hooks): hooks/g.rb")
      expect(again.trash_dir).to be_nil
      expect(File.read(target)).to eq("# the source's hook\n")
      expect(Dir.exist?(File.join(bundles_dir, "hb", "hooks"))).to be(false)
    end
  end

  describe "asset dry run" do
    let(:assets) { %w[plugin.rb guardrails/r.yml scripts/s.sh] }

    def asset_bundle(version, plugin:)
      dir = File.join(tmpdir, "assets-#{version}")
      { "a.md" => "# A\n", "plugin.rb" => plugin, "guardrails/r.yml" => "rules: []\n",
        "scripts/s.sh" => "#!/bin/sh\necho 1\n" }.each do |file, text|
        FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
        File.write(File.join(dir, file), text)
      end
      File.write(File.join(dir, "manifest.yml"), YAML.dump(
        "name" => "assets", "version" => version, "scope" => "system", "files" => { "a.md" => "sha256:fake" },
        "plugin" => { "file" => "plugin.rb" },
        "scripts" => { "s.sh" => "" }
      ))
      dir
    end

    def run_assets(dir, **opts)
      described_class.new(source: dir, name: "assets", scope: "system", strict: true, **opts).tap(&:run)
    end

    it "reports each asset as the real run does, with would_ where it would write" do
      run_assets(asset_bundle("1.0.0", plugin: "# plugin 1\n"))
      v2 = asset_bundle("2.0.0", plugin: "# plugin 2\n")

      dry = run_assets(v2, upgrade: true, dry_run: true)
      real = run_assets(v2, upgrade: true)

      words = { updated: :would_update, installed: :would_install }
      expect(dry.results.slice(*assets)).to eq(real.results.slice(*assets).transform_values do |result|
        result.with(word: words.fetch(result.word, result.word))
      end)
      expect(dry.results["plugin.rb"].word).to eq(:would_update)
      expect(dry.summary).to include("Would update: plugin.rb\n").and include("Up to date: a.md, guardrails/r.yml, scripts/s.sh")
      expect(dry.summary.lines.grep(/\ASkipped:/).join).not_to match(%r{plugin\.rb|guardrails/|scripts/})
    end

    it "lists an unchanged memory and an unchanged rule as up to date, as the real run does" do
      run_assets(asset_bundle("1.0.0", plugin: "# plugin 1\n"))
      v2 = asset_bundle("2.0.0", plugin: "# plugin 2\n")

      dry = run_assets(v2, upgrade: true, dry_run: true)
      real = run_assets(v2, upgrade: true)

      [dry, real].each do |run|
        expect(run.summary.lines.grep(/\AUp to date:/).join).to include("a.md").and include("guardrails/r.yml")
        expect(run.summary).not_to match(/^Skipped:/)
      end
    end

    it "says would install for each asset of a fresh bundle, and writes nothing" do
      dry = run_assets(asset_bundle("1.0.0", plugin: "# plugin 1\n"), dry_run: true)

      expect(dry.results.slice(*assets)).to eq(assets.to_h { |asset| [asset, Samagotchi::MemoryBundle::Installer::FileResult.new(word: :would_install)] })
      expect(Dir.exist?(File.join(bundles_dir, "assets"))).to be false
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
      described_class.new(source: plain, name: "sample-needs", scope: "system", force: true, upgrade: true).run
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "sample-needs").read).not_to have_key(:needs)
    end
  end

  it "lists a plugin and a script an upgrade's new version adds under Installed, not Updated" do
    first = write_bundle(File.join(tmpdir, "v1"), { "a.md" => "# A\n" }, name: "adds", version: "1.0.0")
    described_class.new(source: first, name: "adds", scope: "system", strict: false).run
    second = write_bundle(File.join(tmpdir, "v2"), { "a.md" => "# A\n" }, name: "adds", version: "1.1.0")
    File.write(File.join(second, "plugin.rb"), "class Plugin; def register(chi) = nil; end\n")
    FileUtils.mkdir_p(File.join(second, "scripts"))
    File.write(File.join(second, "scripts", "s.sh"), "#!/bin/sh\n")
    manifest = YAML.safe_load_file(File.join(second, "manifest.yml"))
    File.write(File.join(second, "manifest.yml"), YAML.dump(manifest.merge("plugin" => { "file" => "plugin.rb" }, "scripts" => { "s.sh" => "" })))

    dry = described_class.new(source: second, name: "adds", scope: "system", strict: false, upgrade: true, dry_run: true).tap(&:run)
    expect(dry.summary).to include("Would install: plugin.rb, scripts/s.sh\n")
    up = described_class.new(source: second, name: "adds", scope: "system", strict: false, upgrade: true).tap(&:run)
    expect(up.summary).to include("Installed: plugin.rb, scripts/s.sh\n")
    expect(up.summary).not_to include("Updated:")
  end

  # A manifest can take any name; the source decides who may install under it.
  describe "a bundle of the same name from another source" do
    let(:plugin_fixture) { File.expand_path("../../fixtures/sample_plugin_bundle", __dir__) }
    let(:record) { -> { Samagotchi::MemoryBundle::Provenance.new(name: "sample-plugin").read } }
    let(:plugin_path) { File.join(bundles_dir, "sample-plugin", "plugin", "plugin.rb") }

    def squatter(name: "sample-plugin", version: "9.9.9")
      write_bundle(File.join(tmpdir, "squat"), { "evil_note.md" => "# evil\n" }, name: name, version: version)
    end

    def run(source, name: "sample-plugin", **opts)
      described_class.new(source: source, name: name, scope: "system", strict: true, **opts).tap(&:run)
    end

    before { run(plugin_fixture) }

    it "refuses a plain install, --force too, and leaves the plugin and the record as they were" do
      src = squatter
      [{}, { force: true }, { dry_run: true }].each do |opts|
        expect { run(src, **opts) }.to raise_error(
          described_class::InstallError,
          "sample-plugin is installed from #{plugin_fixture}; `chi bundle upgrade #{src}` switches its source, " \
          "or `chi bundle uninstall sample-plugin` first"
        )
      end
      expect(File.exist?(plugin_path)).to be true
      expect(record.call).to include(source: plugin_fixture, version: "1.0.0")
      expect(File.exist?(File.join(system_memories_dir, "evil_note.md"))).to be false
    end

    it "lets an upgrade switch the source, and says so first in the summary (a dry run too)" do
      src = squatter
      dry = run(src, upgrade: true, dry_run: true)
      expect(dry.summary.lines.first).to eq("Source changes: #{plugin_fixture} → #{src}\n")
      expect(record.call[:source]).to eq(plugin_fixture)

      up = run(src, upgrade: true)
      expect(up.source_change).to eq([plugin_fixture, src])
      expect(up.summary.lines.first).to eq("Source changes: #{plugin_fixture} → #{src}\n")
      expect(record.call).to include(source: src, version: "9.9.9")
      expect(File.exist?(plugin_path)).to be false
    end

    it "changes nothing for a reinstall or an upgrade from the same source" do
      again = run(plugin_fixture)
      expect(again.summary).to include("sample-plugin was already installed")
      up = run(plugin_fixture, upgrade: true)
      expect(up.source_change).to be_nil
      expect(up.summary).not_to include("Source changes")
    end

    it "takes a git URL with another #ref, or an older record's relative path, as the same source" do
      url = "https://example.com/x/sample-plugin.git"
      prepared = lambda do
        extract = File.join(tmpdir, "extract-#{rand(100_000)}")
        FileUtils.cp_r(plugin_fixture, extract)
        Samagotchi::MemoryBundle::PreparedSource.new(dir: extract, owned: true, commit: "abc")
      end
      run(url, upgrade: true, force: true, prepared: prepared.call)
      expect(run("#{url}#v2", prepared: prepared.call).source_change).to be_nil
      expect(run("#{url}/", upgrade: true, prepared: prepared.call).source_change).to be_nil

      manifest = File.join(bundles_dir, "sample-plugin", "manifest.json")
      File.write(manifest, JSON.generate(JSON.parse(File.read(manifest)).merge("source" => "./sample_plugin_bundle")))
      expect { run(squatter) }.not_to raise_error
    end
  end

  describe "a name chi ships" do
    let(:shipped_btw) { File.join(Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR, "btw") }

    def run(source, **opts)
      described_class.new(source: source, name: "btw", scope: "system", strict: true, **opts).tap(&:run)
    end

    def fake_btw = write_bundle(File.join(tmpdir, "fake"), { "evil_note.md" => "# evil\n" }, name: "btw", version: "9.9.9")

    it "is refused from a source that isn't chi's, installed or not, install or upgrade, unless --force" do
      message = "btw is a bundle shipped with chi; #{fake_btw} isn't chi's copy of it (--force to install it anyway)"
      expect { run(fake_btw) }.to raise_error(described_class::InstallError, message)
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read).to be_nil

      run(shipped_btw)
      expect { run(fake_btw, upgrade: true) }.to raise_error(described_class::InstallError, message)
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:source]).to eq(shipped_btw)

      expect(run(fake_btw, upgrade: true, force: true).source_change).to eq([shipped_btw, fake_btw])
    end

    it "takes a fork's lib/samagotchi/bundles/btw (or an archive there) as not chi's copy" do
      fork = File.join(tmpdir, "fork", "lib", "samagotchi", "bundles", "btw")
      FileUtils.mkdir_p(File.dirname(fork))
      FileUtils.cp_r(shipped_btw, fork)
      expect { run(fork) }.to raise_error(described_class::InstallError, /\Abtw is a bundle shipped with chi; #{Regexp.escape(fork)} isn't/)
      tar = File.join(File.dirname(fork), "btw.tar.gz")
      expect(system("tar", "-czf", tar, "-C", fork, ".")).to be(true)
      expect { run(tar) }.to raise_error(described_class::InstallError, /\Abtw is a bundle shipped with chi; #{Regexp.escape(tar)} isn't/)
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read).to be_nil
    end

    # --force passes the shipped-name rule, not the plain-install one: a
    # fork's dir looks like a shipped dir by its path, but isn't chi's btw.
    it "a fork's lib/samagotchi/bundles/btw is another source than chi's btw, --force or not" do
      fork = File.join(tmpdir, "fork", "lib", "samagotchi", "bundles", "btw")
      FileUtils.mkdir_p(File.dirname(fork))
      FileUtils.cp_r(shipped_btw, fork)
      run(shipped_btw)

      expect { run(fork, force: true) }.to raise_error(described_class::InstallError, /\Abtw is installed from #{Regexp.escape(shipped_btw)};/)
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:source]).to eq(shipped_btw)
      expect(run(fork, upgrade: true, force: true).summary.lines.first).to eq("Source changes: #{shipped_btw} → #{fork}\n")
    end

    # .bundles/BTW is .bundles/btw on a case-insensitive file system (macOS).
    it "is a shipped name in any case, and a name differing from an installed one only in case is refused" do
      upper = write_bundle(File.join(tmpdir, "upper"), { "evil_note.md" => "# evil\n" }, name: "BTW", version: "9.9.9")
      install_upper = -> { described_class.new(source: upper, name: "BTW", scope: "system", strict: true, upgrade: true, force: true).run }
      expect { described_class.new(source: upper, name: "BTW", scope: "system", strict: true).run }
        .to raise_error(described_class::InstallError, "BTW is btw, a bundle shipped with chi; #{upper} isn't chi's copy of it " \
                                                       "(--force to install it anyway)")

      run(shipped_btw)
      expect { install_upper.call }.to raise_error(described_class::InstallError, "BTW differs only in case from the installed btw")
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read).to include(source: shipped_btw)
      expect(File.exist?(File.join(system_memories_dir, "evil_note.md"))).to be false
    end

    it "upgrades from chi's dir over a record of an older gem's, with no source change" do
      run(shipped_btw)
      manifest = File.join(bundles_dir, "btw", "manifest.json")
      old = "/gems/samagotchi-0.23.0/lib/samagotchi/bundles/btw"
      File.write(manifest, JSON.generate(JSON.parse(File.read(manifest)).merge("source" => old)))

      expect(run(shipped_btw, upgrade: true).source_change).to be_nil
      expect(run(shipped_btw).summary).to include("btw was already installed")
    end
  end

  # A tar, zip or git repo keeps symlinks; copying through one would put any
  # file the user can read into a memory, a hook or the plugin.
  describe "symlinks in a bundle" do
    let(:secret) { File.join(tmpdir, "secret.txt").tap { |p| File.write(p, "SECRET-TOKEN-123\n") } }

    def config_home_mentions?(text)
      Dir.glob(File.join(tmpdir, "config", "**", "*"), File::FNM_DOTMATCH).any? do |path|
        File.file?(path) && !File.symlink?(path) && File.binread(path).include?(text)
      end
    end

    def linky_dir(manifest_extra = {})
      dir = File.join(tmpdir, "linky")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "manifest.yml"), YAML.dump({ "name" => "linky", "version" => "1.0.0" }.merge(manifest_extra)))
      dir
    end

    it "a tar whose memory links outside installs nothing for it, warns, and copies the target nowhere" do
      dir = linky_dir
      File.symlink(secret, File.join(dir, "notes.md"))
      tar = File.join(tmpdir, "linky.tar.gz")
      system("tar", "-czf", tar, "linky", chdir: tmpdir)

      installer = installer_for(source: tar, name: "linky", scope: "system").tap(&:run)

      expect(installer.results).not_to have_key("notes.md")
      expect(installer.summary).to include("notes.md is a symlink (not installed)")
      expect(File.exist?(File.join(system_memories_dir, "notes.md"))).to be false
      expect(config_home_mentions?("SECRET-TOKEN-123")).to be false
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "linky").read[:files]).to eq({})
    end

    # A flat archive or a git repo puts the links at the extract's top
    # level; copying them must keep them links (not copies of their target).
    it "a flat tar with a top-level memory link, a link to that link and a linked hooks dir: refused, nothing copied" do
      dir = linky_dir
      File.symlink(secret, File.join(dir, "notes.md"))
      File.symlink("notes.md", File.join(dir, "chain.md"))
      outside_hooks = File.join(tmpdir, "outside-hooks")
      FileUtils.mkdir_p(outside_hooks)
      File.write(File.join(outside_hooks, "evil.rb"), "# SECRET-TOKEN-123\n")
      File.symlink(outside_hooks, File.join(dir, "hooks"))
      tar = File.join(tmpdir, "flat.tar.gz")
      expect(system("tar", "-czf", tar, "-C", dir, ".")).to be(true)

      expect { installer_for(source: tar, name: "linky", scope: "system").run }
        .to raise_error(described_class::InstallError, "hooks/evil.rb: #{Samagotchi::MemoryBundle::Manifest::HooksRetired::WORDS}")
      expect(Dir.exist?(File.join(bundles_dir, "linky"))).to be false
      expect(config_home_mentions?("SECRET-TOKEN-123")).to be false
    end

    it "a git repo (file:// URL) with a top-level memory link installs nothing for it" do
      dir = linky_dir
      File.symlink(secret, File.join(dir, "notes.md"))
      git = ->(*args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) }
      expect(git.call("init", "-q") && git.call("add", ".") &&
             git.call("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "v1")).to be(true)

      installer = installer_for(source: "file://#{dir}", name: "linky", scope: "system").tap(&:run)

      expect(installer.warnings).to include("notes.md is a symlink (not installed)")
      expect(config_home_mentions?("SECRET-TOKEN-123")).to be false
    end

    it "skips a linked guardrails dir with a warning" do
      dir = linky_dir
      outside_rules = File.join(tmpdir, "rules")
      FileUtils.mkdir_p(outside_rules)
      File.write(File.join(outside_rules, "r.yml"), "SECRET-TOKEN-123\n")
      File.symlink(outside_rules, File.join(dir, "guardrails"))

      installer = installer_for(source: dir, name: "linky", scope: "system")
      installer.run

      expect(installer.warnings).to include("guardrails/r.yml is a symlink (not installed)")
      expect(Dir.exist?(File.join(bundles_dir, "linky", "guardrails"))).to be false
      expect(config_home_mentions?("SECRET-TOKEN-123")).to be false
    end

    it "refuses a plugin file that is a symlink" do
      dir = linky_dir("plugin" => { "file" => "plugin.rb", "sha256" => "" })
      File.symlink(secret, File.join(dir, "plugin.rb"))

      expect { installer_for(source: dir, name: "linky", scope: "system").run }
        .to raise_error(described_class::InstallError, "plugin plugin.rb is a symlink (not installed)")
      expect(config_home_mentions?("SECRET-TOKEN-123")).to be false
    end
  end

  describe "which of a bundle's *.md files are memories" do
    # A bundle dir with +md+ (name => content) and a manifest listing +listed+
    # (nil: no files: key, {}: an empty map).
    def raw_bundle(md, listed:, name: "repo-bundle")
      dir = File.join(tmpdir, name)
      FileUtils.mkdir_p(dir)
      md.each { |f, c| File.write(File.join(dir, f), c) }
      manifest = { "name" => name, "version" => "1.0.0" }
      manifest["files"] = listed.to_h { |f| [f, "sha256:#{Digest::SHA256.hexdigest(md.fetch(f, ""))}"] } unless listed.nil?
      File.write(File.join(dir, "manifest.yml"), YAML.dump(manifest))
      dir
    end

    let(:repo_files) do
      { "real.md" => "# Real\n", "README.md" => "# Readme\n", "LICENSE.md" => "MIT\n",
        "changelog.md" => "# Changes\n", "Contributing.md" => "x\n", "CODE_OF_CONDUCT.md" => "x\n",
        "SECURITY.md" => "x\n", "notes.md" => "# Notes\n" }
    end

    def index_text = File.read(File.join(system_memories_dir, "index.md"))

    it "installs only the files a non-empty files: lists" do
      dir = raw_bundle(repo_files, listed: ["real.md"])
      installer = installer_for(source: dir, name: "repo-bundle", scope: "system").tap(&:run)

      expect(installer.results.keys).to eq(["real.md"])
      expect(Dir.children(system_memories_dir).grep(/\.md\z/).sort).to eq(%w[index.md real.md])
      expect(index_text).not_to include("**README**")
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "repo-bundle").read[:files].keys.map(&:to_s)).to eq(["real.md"])
    end

    it "installs a listed file even with a repo-meta name (a built bundle of a user's security memory)" do
      dir = raw_bundle({ "security.md" => "# My security notes\n" }, listed: ["security.md"])
      installer_for(source: dir, name: "repo-bundle", scope: "system").run

      expect(File.exist?(File.join(system_memories_dir, "security.md"))).to be true
    end

    it "warns about a files: entry the bundle doesn't ship" do
      dir = raw_bundle({ "real.md" => "# Real\n" }, listed: %w[real.md gone.md])
      installer = installer_for(source: dir, name: "repo-bundle", scope: "system").tap(&:run)

      expect(installer.warnings).to include(a_string_matching(/files: names gone\.md, which the bundle doesn't ship/))
    end

    [nil, []].each do |listed|
      it "without a list (files: #{listed.nil? ? "absent" : "{}"}) installs every *.md but the repo-meta ones" do
        dir = raw_bundle(repo_files, listed: listed)
        installer = described_class.new(source: dir, name: "repo-bundle", scope: "system", strict: true).tap(&:run)

        expect(installer.results.keys.sort).to eq(%w[notes.md real.md])
        expect(File.exist?(File.join(system_memories_dir, "README.md"))).to be false
        expect(index_text).not_to match(/\*\*(README|LICENSE|changelog)\*\*/)
      end
    end

    it "an upgrade moves a README an older install made a memory to the trash" do
      # chi 0.74.0 and earlier installed every *.md; an old install that owns
      # README.md is set up here by listing it.
      old = raw_bundle({ "real.md" => "# Real\n", "README.md" => "# Readme\n" }, listed: %w[real.md README.md])
      installer_for(source: old, name: "repo-bundle", scope: "system").run
      expect(index_text).to include("**README**")

      new_dir = raw_bundle({ "real.md" => "# Real\n", "README.md" => "# Readme\n" }, listed: nil, name: "repo-bundle")
      up = described_class.new(source: new_dir, name: "repo-bundle", scope: "system", strict: true, upgrade: true).tap(&:run)

      expect(up.results["README.md"].word).to eq(:removed)
      expect(File.exist?(File.join(system_memories_dir, "README.md"))).to be false
      expect(index_text).not_to include("**README**")
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "repo-bundle").read[:files].keys.map(&:to_s)).to eq(["real.md"])
    end

    # A plain re-install leaves the memories it skips alone (the summary says
    # so), but it keeps the record of the ones it no longer ships, so
    # that upgrade still moves them to the trash.
    it "a plain re-install keeps owning a README an older install made a memory, so the upgrade removes it" do
      old = raw_bundle({ "real.md" => "# Real\n", "README.md" => "# Readme\n" }, listed: %w[real.md README.md])
      installer_for(source: old, name: "repo-bundle", scope: "system").run

      new_dir = raw_bundle({ "real.md" => "# Real\n", "README.md" => "# Readme\n" }, listed: nil, name: "repo-bundle")
      reinstall = installer_for(source: new_dir, name: "repo-bundle", scope: "system").tap(&:run)
      expect(reinstall.results.keys).to eq(["real.md"])
      expect(File.exist?(File.join(system_memories_dir, "README.md"))).to be true
      expect(Samagotchi::MemoryBundle::Provenance.new(name: "repo-bundle").read[:files].keys.map(&:to_s))
        .to contain_exactly("real.md", "README.md")

      up = described_class.new(source: new_dir, name: "repo-bundle", scope: "system", strict: true, upgrade: true).tap(&:run)
      expect(up.results["README.md"].word).to eq(:removed)
      expect(File.exist?(File.join(system_memories_dir, "README.md"))).to be false
      expect(index_text).not_to include("**README**")
    end

    # The record a plain re-install keeps is the old base: a dropped file the
    # user edited stays theirs (the upgrade keeps it), one the user deleted
    # isn't recorded, and a file this version ships keeps its own record.
    it "a plain re-install keeps a dropped file's old base, and no record of one the user deleted" do
      old = raw_bundle({ "real.md" => "# Real\n", "README.md" => "# Readme\n", "LICENSE.md" => "MIT\n" },
                       listed: %w[real.md README.md LICENSE.md])
      installer_for(source: old, name: "repo-bundle", scope: "system").run
      File.write(File.join(system_memories_dir, "README.md"), "# Readme, my notes\n")
      FileUtils.rm(File.join(system_memories_dir, "LICENSE.md"))
      FileUtils.rm(File.join(system_memories_dir, "real.md"))

      new_dir = raw_bundle({ "real.md" => "# Real v2\n", "README.md" => "# Readme\n", "LICENSE.md" => "MIT\n" }, listed: nil)
      installer_for(source: new_dir, name: "repo-bundle", scope: "system").run
      files = Samagotchi::MemoryBundle::Provenance.new(name: "repo-bundle").read[:files]
      expect(files.keys.map(&:to_s)).to contain_exactly("real.md", "README.md")
      expect(files[:"real.md"][:checksum]).to eq(Digest::SHA256.hexdigest("# Real v2\n"))
      expect(files[:"README.md"][:checksum]).to eq(Digest::SHA256.hexdigest("# Readme\n"))

      up = described_class.new(source: new_dir, name: "repo-bundle", scope: "system", strict: true, upgrade: true).tap(&:run)
      expect(up.results["README.md"].word).to eq(:kept_pruned)
      expect(File.read(File.join(system_memories_dir, "README.md"))).to eq("# Readme, my notes\n")
    end
  end
end
