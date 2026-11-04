# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "stringio"

require "samagotchi/bundle_command"
require "samagotchi/terminal_ui"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/status"

# What an install or upgrade may never do to an edit: lose it, or bury the
# miss. (Trash#copy itself: trash_spec.rb.)
RSpec.describe "Kept edits in a bundle" do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-kept-edits-") }
  let(:memories) { Samagotchi::MemoryPaths.system_dir }
  let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "demo") }
  let(:target) { File.join(memories, "a.md") }
  let(:source) { File.join(tmpdir, "src") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  after { FileUtils.rm_rf(tmpdir) }

  def write_source(version, files = { "a.md" => "v#{version}\n" }, extra: {}, dir: source)
    FileUtils.rm_rf(dir)
    FileUtils.mkdir_p(dir)
    files.each { |name, text| File.write(File.join(dir, name), text) }
    File.write(File.join(dir, "manifest.yml"),
               YAML.dump({ "name" => "demo", "version" => version, "scope" => "system",
                           "files" => files.keys.to_h { |k| [k, "sha256:fake"] } }.merge(extra)))
    dir
  end

  def run_installer(from = source, **opts)
    Samagotchi::MemoryBundle::Installer.new(source: from, name: "demo", strict: true, **opts).tap(&:run)
  end

  def trash_files
    root = File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash")
    Dir.glob(File.join(root, "*", "**", "*")).select { |f| File.file?(f) }.to_h do |file|
      [file.split("/.trash/").last.split("/", 2).last, File.read(file)]
    end
  end

  describe "a dry run of an upgrade" do
    before do
      write_source("1.0.0", { "a.md" => "a1\n", "b.md" => "b1\n", "c.md" => "c1\n" })
      run_installer
      File.write(target, "edited\n")
      File.write(File.join(memories, "b.md"), "edited\n")
    end

    it "names only a real conflict, with its three sides, and moves nothing" do
      write_source("2.0.0", { "a.md" => "a2\n", "b.md" => "b1\n", "c.md" => "c2\n" })
      dry = run_installer(upgrade: true, dry_run: true)

      expect(dry.conflicts).to eq("a.md" => { base: provenance.base_path("a.md"), current: target, incoming: File.join(source, "a.md") })
      expect(dry.results.slice("a.md", "b.md", "c.md").transform_values { |r| r[:status] })
        .to eq("a.md" => "conflict", "b.md" => "keep", "c.md" => "fast_forward")
      expect(File.read(target)).to eq("edited\n")
      expect(provenance.record.version).to eq("1.0.0")
    end

    it "says a kept edit is kept, with no checksum mismatch for it" do
      write_source("2.0.0", { "a.md" => "a2\n", "b.md" => "b1\n", "c.md" => "c2\n" })
      dry = run_installer(upgrade: true, dry_run: true)

      expect(dry.summary).to include("Kept (local edits preserved): b.md")
      expect(dry.warnings.grep(/Checksum mismatch for b\.md/)).to be_empty
    end

    it "prints no checksum mismatch for a file a plain install would skip" do
      dry = run_installer(write_source("1.0.0", { "a.md" => "a1\n", "b.md" => "b1\n", "c.md" => "c1\n" }), dry_run: true)

      expect(dry.results["a.md"][:status]).to eq("would_skip")
      expect(dry.warnings.grep(/Checksum mismatch for a\.md/)).to be_empty
    end
  end

  # Enough common text between the two edits that git keeps them apart.
  def doc(intro: "the intro", tail: "the tail")
    "# Title\n\n#{intro}\n\n## Steps\n\n1. first step\n2. second step\n3. third step\n\n## Notes\n\n#{tail}\n"
  end

  describe "an upgrade over an edit that merges clean" do
    before do
      write_source("1.0.0", { "a.md" => doc })
      run_installer
      File.write(target, doc(intro: "my intro"))
    end

    it "merges, with no markers, and says so" do
      up = run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(File.read(target)).to eq(doc(intro: "my intro", tail: "tail two"))
      expect(up.results["a.md"][:status]).to eq("merged")
      expect(up.merged_files).to eq(["a.md"])
      expect(up.conflicts).to be_empty
      expect(up.summary).to include("Merged: a.md")
      expect(up.warnings.join).not_to include("Conflict", "Checksum mismatch")
    end

    # Taking the merged file as the base makes current == base, and the next
    # upgrade fast-forwards over the edit.
    it "keeps the edit through three upgrades in a row, the base the incoming file each time" do
      %w[two three four].each_with_index do |word, i|
        incoming = doc(tail: "tail #{word}")
        up = run_installer(write_source("#{i + 2}.0.0", { "a.md" => incoming }), upgrade: true)

        expect(up.results["a.md"][:status]).to eq("merged")
        expect(File.read(target)).to eq(doc(intro: "my intro", tail: "tail #{word}"))
        expect(File.read(provenance.base_path("a.md"))).to eq(incoming)
        expect(provenance.read[:files][:"a.md"]).to eq(checksum: Digest::SHA256.hexdigest(incoming))
      end
    end

    it "still calls the file edited: a status of modified, an uninstall that refuses" do
      run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(Samagotchi::MemoryBundle::Status.bundle_status("demo").files["a.md"]).to include(modified: true, conflict: false)
      expect { uninstall }.to raise_error(Samagotchi::MemoryBundle::Uninstaller::UninstallError)
    end

    it "copies the old file to the trash first" do
      up = run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(trash_files).to eq("a.md" => doc(intro: "my intro"))
      expect(up.summary).to include("Copied to the trash first: a.md (#{up.trash_dir})")
    end

    it "keeps a file that already holds the bundle's change, with no claim of a merge, and moves its base" do
      both = doc(intro: "my intro", tail: "tail two")
      File.write(target, both)
      up = run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(up.results["a.md"]).to eq(status: "kept", reason: "local edits already hold the bundle's changes")
      expect(up.merged_files).to be_empty
      expect(trash_files).to be_empty
      expect(File.read(target)).to eq(both)
      expect(File.read(provenance.base_path("a.md"))).to eq(doc(tail: "tail two"))

      dry = run_installer(write_source("3.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true, dry_run: true)
      expect(dry.summary).to include("Kept (local edits preserved): a.md")
    end

    it "writes through a symlink, keeping the link and its target's mode" do
      real = File.join(tmpdir, "elsewhere.md")
      File.write(real, doc(intro: "my intro"))
      File.chmod(0o640, real)
      FileUtils.rm_f(target)
      File.symlink(real, target)
      run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(File.symlink?(target)).to be true
      expect(File.read(real)).to eq(doc(intro: "my intro", tail: "tail two"))
      expect(File.stat(real).mode & 0o777).to eq(0o640)
      expect(trash_files).to eq("a.md" => doc(intro: "my intro"))
    end

    it "keeps a plain file's mode" do
      File.chmod(0o600, target)
      run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(File.stat(target).mode & 0o777).to eq(0o600)
    end

    it "leaves a write that came in during the merge, as a conflict with the old base and the mark" do
      allow_any_instance_of(Samagotchi::MemoryBundle::Trash).to receive(:copy).and_wrap_original do |copy, *args, **opts|
        File.write(target, "a live memory_write\n")
        copy.call(*args, **opts)
      end
      up = run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true)

      expect(File.read(target)).to eq("a live memory_write\n")
      expect(up.results["a.md"][:status]).to eq("conflict")
      expect(up.warnings).to include(a_string_including("Conflict in a.md: no merge possible (#{Samagotchi::MemoryBundle::TextMerge::RACED})"))
      expect(File.read(provenance.base_path("a.md"))).to eq(doc)
      expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
      expect(Dir.glob(File.join(memories, "*.tmp"))).to be_empty
    end

    it "says would merge in a dry run, and writes nothing" do
      dry = run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true, dry_run: true)

      expect(dry.results["a.md"][:status]).to eq("would_merge")
      expect(dry.summary).to include("Would merge: a.md")
      expect(dry.summary).not_to include("Merged:", "Checksum mismatch")
      expect(dry.conflicts).to be_empty
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(File.read(provenance.base_path("a.md"))).to eq(doc)
      expect(trash_files).to be_empty
      expect(provenance.read[:version]).to eq("1.0.0")
    end

    it "fails cleanly when the trash can't hold the copy, the file and record as they were" do
      File.write(File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash"), "in the way\n")

      expect { run_installer(write_source("2.0.0", { "a.md" => doc(tail: "tail two") }), upgrade: true) }
        .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /nothing was lost/)
      expect(File.read(target)).to eq(doc(intro: "my intro"))
      expect(provenance.read[:version]).to eq("1.0.0")
    end

    it "unions a Changelog both sides added to" do
      log = "#{doc}\n## Changelog\n- one\n"
      write_source("1.0.0", { "a.md" => log })
      run_installer(write_source("1.0.0", { "a.md" => log }), force: true)
      File.write(target, "#{log}- mine\n")
      run_installer(write_source("2.0.0", { "a.md" => "#{log}- theirs\n" }), upgrade: true)

      expect(File.read(target)).to eq("#{log}- mine\n- theirs\n")
      expect(File.read(provenance.base_path("a.md"))).to eq("#{log}- theirs\n")
    end
  end

  describe "an upgrade that can't merge" do
    before do
      write_source("1.0.0")
      run_installer
      File.write(target, "edited\n")
    end

    def expect_untouched(up, version: "2.0.0")
      expect(File.read(target)).to eq("edited\n")
      expect(up.results["a.md"][:status]).to eq("conflict")
      expect(up.conflicts).to have_key("a.md")
      expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
      expect(provenance.read[:version]).to eq(version)
      expect(trash_files).to be_empty
    end

    it "leaves a real conflict untouched, no markers, the base old and the mark on" do
      up = run_installer(write_source("2.0.0"), upgrade: true)

      expect_untouched(up)
      expect(File.read(provenance.base_path("a.md"))).to eq("v1.0.0\n")
      expect(up.warnings).to include(a_string_including("Conflict in a.md: local edits conflict with bundle update"))
    end

    it "conflicts again at the next upgrade" do
      run_installer(write_source("2.0.0"), upgrade: true)
      expect_untouched(run_installer(write_source("3.0.0"), upgrade: true), version: "3.0.0")
    end

    it "says why when there is no git, and keeps the file" do
      FileUtils.mkdir_p(File.join(tmpdir, "no-git"))
      up = with_env("PATH" => File.join(tmpdir, "no-git")) { run_installer(write_source("2.0.0"), upgrade: true) }

      expect_untouched(up)
      expect(File.read(provenance.base_path("a.md"))).to eq("v1.0.0\n")
      expect(up.warnings).to include(a_string_including("Conflict in a.md: no merge possible (git not found), local edits kept"))
    end

    it "says why when there is no base, and keeps the file with none" do
      FileUtils.rm_f(provenance.base_path("a.md"))
      up = run_installer(write_source("2.0.0"), upgrade: true)

      expect_untouched(up)
      expect(File.exist?(provenance.base_path("a.md"))).to be false
      expect(up.warnings).to include(a_string_including("no merge possible (no recorded base)"))
    end

    it "calls a real conflict a conflict in a dry run, with no write" do
      dry = run_installer(write_source("2.0.0"), upgrade: true, dry_run: true)

      expect(dry.results["a.md"][:status]).to eq("conflict")
      expect(dry.summary).not_to include("Would merge")
      expect(File.read(target)).to eq("edited\n")
    end
  end

  describe "--force over a file that differs" do
    before do
      write_source("1.0.0")
      run_installer
    end

    it "copies an edit to the trash before an upgrade overwrites it, and says so" do
      File.write(target, "edited\n")
      up = run_installer(write_source("2.0.0"), upgrade: true, force: true)

      expect(File.read(target)).to eq("v2.0.0\n")
      expect(trash_files).to eq("a.md" => "edited\n")
      expect(up.summary).to include("Copied to the trash first: a.md (#{up.trash_dir})")
    end

    it "copies a user's own same-name file the bundle never owned" do
      File.write(File.join(memories, "mine.md"), "my own\n")
      up = run_installer(write_source("1.0.0", { "a.md" => "v1.0.0\n", "mine.md" => "theirs\n" }), force: true)

      expect(File.read(File.join(memories, "mine.md"))).to eq("theirs\n")
      expect(trash_files).to eq("mine.md" => "my own\n")
      expect(up.summary).to include("Copied to the trash first: mine.md")
    end

    it "copies nothing when the file has the incoming bytes, and leaves no trash dir" do
      up = run_installer(force: true)

      expect(trash_files).to be_empty
      expect(up.trash_dir).to be_nil
      expect(up.summary).not_to include("trash")
    end

    it "writes nothing to the trash on a dry run" do
      File.write(target, "edited\n")
      run_installer(write_source("2.0.0"), upgrade: true, force: true, dry_run: true)

      expect(trash_files).to be_empty
      expect(File.read(target)).to eq("edited\n")
    end
  end

  describe "hooks, rules, the plugin and scripts" do
    def asset_source(version, body, hook: "h.rb", rule: "r.yml", plugin: "plugin.rb", script: "s.sh")
      write_source(version, { "a.md" => "same\n" })
      extra = {}
      if hook
        FileUtils.mkdir_p(File.join(source, "hooks"))
        File.write(File.join(source, "hooks", hook), "# hook #{body}\n")
        extra["hooks"] = { hook => { "event" => "after_turn", "on_error" => "log" } }
      else
        extra["hooks"] = {}
      end
      if rule
        FileUtils.mkdir_p(File.join(source, "guardrails"))
        File.write(File.join(source, "guardrails", rule), "# rule #{body}\n")
      end
      if plugin
        File.write(File.join(source, plugin), "# plugin #{body}\n")
        extra["plugin"] = { "file" => plugin, "sha256" => "" }
      end
      if script
        FileUtils.mkdir_p(File.join(source, "scripts"))
        File.write(File.join(source, "scripts", script), "# script #{body}\n")
        extra["scripts"] = { script => { "sha256" => "" } }
      end
      manifest = YAML.safe_load_file(File.join(source, "manifest.yml")).merge(extra)
      File.write(File.join(source, "manifest.yml"), YAML.dump(manifest))
      source
    end

    let(:installed) do
      { "hooks/h.rb" => File.join(provenance.hooks_dir, "h.rb"), "guardrails/r.yml" => File.join(provenance.guardrails_dir, "r.yml"),
        "plugin/plugin.rb" => File.join(provenance.plugin_dir, "plugin.rb"), "scripts/s.sh" => File.join(provenance.scripts_dir, "s.sh") }
    end

    before do
      asset_source("1.0.0", "one")
      run_installer
    end

    it "copies each edited file an upgrade replaces, in its own subfolder, and says so" do
      installed.each_value { |path| File.write(path, "edited #{File.basename(path)}\n") }
      asset_source("2.0.0", "two")
      up = run_installer(upgrade: true)

      expect(trash_files).to eq(installed.to_h { |label, path| [label, "edited #{File.basename(path)}\n"] })
      expect(File.read(installed["hooks/h.rb"])).to eq("# hook two\n")
      expect(up.summary).to include("Copied to the trash first: ")
      expect(up.summary).to include("hooks/h.rb", "guardrails/r.yml", "plugin/plugin.rb", "scripts/s.sh")
    end

    it "keeps same-name files of two kinds apart" do
      asset_source("1.0.1", "one", hook: "x", rule: nil, plugin: nil, script: "x")
      run_installer(upgrade: true)
      File.write(File.join(provenance.hooks_dir, "x"), "my hook\n")
      File.write(File.join(provenance.scripts_dir, "x"), "my script\n")
      asset_source("2.0.0", "two", hook: "x", rule: nil, plugin: nil, script: "x")
      run_installer(upgrade: true)

      expect(trash_files).to eq("hooks/x" => "my hook\n", "scripts/x" => "my script\n")
    end

    it "copies each edited file an upgrade prunes" do
      installed.each_value { |path| File.write(path, "edited\n") }
      asset_source("2.0.0", "two", hook: nil, rule: nil, plugin: nil, script: nil)
      run_installer(upgrade: true)

      expect(trash_files.keys).to match_array(installed.keys)
      installed.each_value { |path| expect(File.exist?(path)).to be false }
    end

    it "copies nothing for unedited files" do
      asset_source("2.0.0", "two")
      up = run_installer(upgrade: true)

      expect(trash_files).to be_empty
      expect(up.trash_dir).to be_nil
    end

    it "copies nothing when an edited file already has the incoming bytes" do
      File.write(installed["hooks/h.rb"], "# hook two\n")
      asset_source("2.0.0", "two")
      run_installer(upgrade: true)

      expect(trash_files).to be_empty
    end

    it "copies an edit a plain re-install replaces" do
      File.write(installed["guardrails/r.yml"], "edited\n")
      run_installer

      expect(trash_files).to eq("guardrails/r.yml" => "edited\n")
    end

    it "copies nothing on a dry run" do
      installed.each_value { |path| File.write(path, "edited\n") }
      asset_source("2.0.0", "two")
      run_installer(upgrade: true, dry_run: true)

      expect(trash_files).to be_empty
    end
  end

  describe "a dev install's links" do
    it "are never copied to the trash, replaced or pruned" do
      write_source("1.0.0", { "a.md" => "one\n" }, extra: { "hooks" => { "h.rb" => { "event" => "after_turn" } } })
      FileUtils.mkdir_p(File.join(source, "hooks"))
      File.write(File.join(source, "hooks", "h.rb"), "# hook\n")
      run_installer(dev: true)
      link = File.join(provenance.hooks_dir, "h.rb")
      expect(File.symlink?(link)).to be true

      File.write(File.join(source, "hooks", "h.rb"), "# edited in the source\n")
      run_installer(dev: true)
      expect(trash_files).to be_empty

      FileUtils.rm_f(File.join(source, "hooks", "h.rb"))
      manifest = YAML.safe_load_file(File.join(source, "manifest.yml")).merge("hooks" => {})
      File.write(File.join(source, "manifest.yml"), YAML.dump(manifest))
      run_installer(dev: true)
      expect(trash_files).to be_empty
    end
  end

  describe "the agent step of an upgrade" do
    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }
    let(:b_target) { File.join(memories, "b.md") }

    before do
      write_source("1.0.0", { "a.md" => "a one\n", "b.md" => "b one\n" },
                   extra: { "files" => { "a.md" => { "sha256" => "fake", "description" => "A" },
                                         "b.md" => { "sha256" => "fake", "description" => "B" } } })
      run_installer
      File.write(target, "a edited\n")
      File.write(b_target, "b edited\n")
      write_source("2.0.0", { "a.md" => "a two\n", "b.md" => "b two\n" },
                   extra: { "files" => { "a.md" => { "sha256" => "fake", "description" => "A" },
                                         "b.md" => { "sha256" => "fake", "description" => "B" } } })
    end

    # An upgrade whose agent step (the TerminalUI) does +agent+.
    def upgrade_with_agent(&agent)
      ui = instance_double(Samagotchi::TerminalUI)
      allow(ui).to receive(:run) { agent&.call }
      allow(Samagotchi::TerminalUI).to receive(:new).and_return(ui)
      Samagotchi::BundleCommand.new(["upgrade", source, "--agent"], stdin: StringIO.new, stdout: stdout, stderr: stderr).run
    end

    def entry(key) = provenance.read[:files][key.to_sym]

    it "leaves a file nothing changed as a conflict, says so and exits with CONFLICTS_KEPT" do
      code = upgrade_with_agent

      expect(code).to eq(Samagotchi::BundleCommand::CONFLICTS_KEPT)
      expect(entry("a.md")).to include(conflict: true)
      expect(File.read(provenance.base_path("a.md"))).to eq("a one\n")
      expect(stdout.string).to include("Nothing changed in a.md: still behind", "Nothing changed in b.md: still behind")
      expect(stdout.string).not_to include("resolved interactively")
    end

    it "brings the next upgrade back to a conflict, not a silent keep" do
      upgrade_with_agent
      again = run_installer(upgrade: true)

      expect(again.results["a.md"][:status]).to eq("conflict")
    end

    it "keeps a file that still holds conflict markers as a conflict" do
      code = upgrade_with_agent do
        File.write(target, "<<<<<<< mine\na edited\n=======\na two\n>>>>>>> theirs\n")
        File.write(b_target, "b merged\n")
      end

      expect(code).to eq(Samagotchi::BundleCommand::CONFLICTS_KEPT)
      expect(entry("a.md")).to include(conflict: true)
      expect(stdout.string).to include("a.md still holds conflict markers: still behind")
      expect(entry("b.md")).not_to include(:conflict)
      expect(File.read(provenance.base_path("b.md"))).to eq("b two\n")
      expect(stdout.string).to include("Resolved: b.md")
    end

    it "doesn't take a Markdown rule or heading underline for a marker" do
      code = upgrade_with_agent do
        File.write(target, "Title\n=======\n> quote\n")
        File.write(b_target, "b merged\n")
      end

      expect(code).to eq(0)
      expect(entry("a.md")).not_to include(:conflict)
    end

    it "keeps a file as a conflict when the bundle's copy went during the step" do
      code = upgrade_with_agent do
        File.write(target, "a merged\n")
        File.write(b_target, "b merged\n")
        FileUtils.rm_f(File.join(source, "a.md"))
      end

      expect(code).to eq(Samagotchi::BundleCommand::CONFLICTS_KEPT)
      expect(entry("a.md")).to include(conflict: true)
      expect(File.read(provenance.base_path("a.md"))).to eq("a one\n")
      expect(stdout.string).to include("The bundle's copy of a.md is gone: still behind.", "Resolved: b.md")
    end

    it "settles every changed file with no markers, moves the base, keeps the description and exits 0" do
      code = upgrade_with_agent do
        File.write(target, "a merged\n")
        File.write(b_target, "b merged\n")
      end

      expect(code).to eq(0)
      expect(entry("a.md")).to eq(checksum: Digest::SHA256.hexdigest("a two\n"), description: "A")
      expect(File.read(provenance.base_path("a.md"))).to eq("a two\n")
      expect(File.read(target)).to eq("a merged\n")
      expect(stdout.string).to include("Upgrade resolved interactively.")
    end
  end

  describe "Provenance#resolve_conflicts" do
    it "keeps the entry's description" do
      old = File.join(tmpdir, "old.md")
      incoming = File.join(tmpdir, "new.md")
      File.write(old, "old\n")
      File.write(incoming, "new\n")
      provenance.write(files: { "a.md" => old }, scope: "system", version: "1", source_path: "/s",
                       conflicts: ["a.md"], file_descriptions: { "a.md" => "What a is" })

      provenance.resolve_conflicts("a.md" => { incoming: incoming, current: old })

      expect(provenance.read[:files][:"a.md"]).to eq(checksum: Digest::SHA256.hexdigest("new\n"), description: "What a is")
    end

    context "when the incoming file is gone" do
      before do
        write_source("1.0.0")
        run_installer
        File.write(target, "edited\n")
        run_installer(write_source("2.0.0"), upgrade: true)
      end

      it "keeps the mark and the base, and answers that it settled nothing" do
        settled = provenance.resolve_conflicts("a.md" => { incoming: File.join(tmpdir, "gone.md"), current: target })

        expect(settled).to eq([])
        expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
        expect(File.read(provenance.base_path("a.md"))).to eq("v1.0.0\n")
      end

      it "leaves the edit safe at the next upgrade" do
        provenance.resolve_conflicts("a.md" => { incoming: File.join(tmpdir, "gone.md"), current: target })
        up = run_installer(write_source("3.0.0"), upgrade: true)

        expect(up.results["a.md"][:status]).to eq("conflict")
        expect(File.read(target)).to eq("edited\n")
      end
    end
  end

  describe "a kept file with no base" do
    before do
      write_source("1.0.0")
      run_installer
      File.write(target, "edited\n")
      FileUtils.rm_f(provenance.base_path("a.md"))
    end

    it "survives two upgrades as a conflict, its base still missing" do
      %w[2.0.0 3.0.0].each do |version|
        up = run_installer(write_source(version), upgrade: true)

        expect(up.results["a.md"][:status]).to eq("conflict")
        expect(File.read(target)).to eq("edited\n")
        expect(File.exist?(provenance.base_path("a.md"))).to be false
        expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
        expect(provenance.read[:version]).to eq(version)
      end
      expect(trash_files).to be_empty
    end

    it "keeps the entry's checksum as recorded, never the edit's" do
      recorded = provenance.read[:files][:"a.md"][:checksum]
      run_installer(write_source("2.0.0"), upgrade: true)

      expect(provenance.read[:files][:"a.md"][:checksum]).to eq(recorded)
    end

    it "gets a base once it is level with the bundle" do
      run_installer(write_source("2.0.0"), upgrade: true)
      File.write(target, "v3.0.0\n")
      run_installer(write_source("3.0.0"), upgrade: true)

      expect(File.read(provenance.base_path("a.md"))).to eq("v3.0.0\n")
      expect(provenance.read[:files][:"a.md"]).not_to include(:conflict)
    end

    it "survives a plain install, then an upgrade" do
      run_installer(write_source("1.0.1"))
      expect(File.exist?(provenance.base_path("a.md"))).to be false

      up = run_installer(write_source("2.0.0"), upgrade: true)
      expect(up.results["a.md"][:status]).to eq("conflict")
      expect(File.read(target)).to eq("edited\n")
    end

    it "stays kept when the bundle stops shipping it, upgrade after upgrade" do
      %w[2.0.0 3.0.0].each do |version|
        up = run_installer(write_source(version, { "z.md" => "z\n" }), upgrade: true)

        expect(up.results["a.md"]).to include(status: "kept_pruned")
        expect(File.read(target)).to eq("edited\n")
        expect(File.exist?(provenance.base_path("a.md"))).to be false
      end
      expect(trash_files).to be_empty
    end

    it "stays recorded through a plain install that no longer ships it" do
      run_installer(write_source("1.0.1", { "z.md" => "z\n" }))

      expect(provenance.read[:files]).to have_key(:"a.md")
      expect(run_installer(write_source("2.0.0", { "z.md" => "z\n" }), upgrade: true).results["a.md"][:status]).to eq("kept_pruned")
    end
  end

  describe "a plain install over a conflict-marked file" do
    before do
      write_source("1.0.0")
      run_installer
      File.write(target, "edited\n")
      run_installer(write_source("2.0.0"), upgrade: true)
      expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
    end

    it "keeps the mark and the base on a file it skipped" do
      up = run_installer(write_source("2.0.0"))

      expect(up.results["a.md"]).to eq(status: "skipped", reason: "already exists")
      expect(provenance.read[:files][:"a.md"]).to include(conflict: true)
      expect(File.read(provenance.base_path("a.md"))).to eq("v1.0.0\n")
    end

    it "keeps it when a newer source moves the version with the file unchanged" do
      run_installer(write_source("3.0.0"))

      data = provenance.read
      expect(data[:version]).to eq("3.0.0")
      expect(data[:files][:"a.md"]).to include(conflict: true)
      expect(File.read(target)).to eq("edited\n")
      expect(File.read(provenance.base_path("a.md"))).to eq("v1.0.0\n")
    end

    it "drops it once the file has the incoming bytes" do
      File.write(target, "v2.0.0\n")
      run_installer(write_source("2.0.0"))

      expect(provenance.read[:files][:"a.md"]).not_to include(:conflict)
    end

    it "doesn't invent one on a file that had none" do
      File.write(File.join(memories, "x.md"), "mine\n")
      run_installer(write_source("2.0.0", { "a.md" => "v2.0.0\n", "x.md" => "theirs\n" }))

      expect(provenance.read[:files]).not_to have_key(:"x.md")
    end
  end

  describe "a conflict-marked record whose base is the user's file" do
    # What 0.149 left for an edit with no base, or a downgrade recreates.
    before do
      write_source("1.0.0")
      run_installer
      File.write(target, "edited\n")
      provenance.write(files: { "a.md" => target }, scope: "system", version: "2.0.0", source_path: source, conflicts: ["a.md"])
    end

    it "copies the file to the trash before the fast-forward, and says so" do
      up = run_installer(write_source("3.0.0"), upgrade: true)

      expect(trash_files).to eq("a.md" => "edited\n")
      expect(File.read(target)).to eq("v3.0.0\n")
      expect(up.summary).to include("Copied to the trash first: a.md (#{up.trash_dir})")
      expect(up.warnings).to include(a_string_including("a.md was marked as kept", "your copy is in the trash"))
      expect(provenance.read[:files][:"a.md"]).not_to include(:conflict)
      expect(File.read(provenance.base_path("a.md"))).to eq("v3.0.0\n")
    end

    it "copies nothing when the mark is gone: an unmarked record like this can't be told from an unedited file" do
      provenance.write(files: { "a.md" => target }, scope: "system", version: "2.0.0", source_path: source)
      run_installer(write_source("3.0.0"), upgrade: true)

      expect(trash_files).to be_empty
    end
  end

  # A bundle with a memory, a hook, a rule, a plugin and a script.
  def full_source(version, memory: true)
    write_source(version, memory ? { "a.md" => "same\n" } : {})
    { "hooks/h.rb" => "# hook\n", "guardrails/r.yml" => "# rule\n", "plugin.rb" => "# plugin\n", "scripts/s.sh" => "# script\n" }.each do |file, text|
      FileUtils.mkdir_p(File.dirname(File.join(source, file)))
      File.write(File.join(source, file), "#{text.chomp} #{version}\n")
    end
    manifest = YAML.safe_load_file(File.join(source, "manifest.yml"))
    manifest.merge!("hooks" => { "h.rb" => { "event" => "after_turn", "on_error" => "log" } },
                    "plugin" => { "file" => "plugin.rb", "sha256" => "" }, "scripts" => { "s.sh" => { "sha256" => "" } })
    File.write(File.join(source, "manifest.yml"), YAML.dump(manifest))
    source
  end

  def installed_assets
    { "hooks/h.rb" => File.join(provenance.hooks_dir, "h.rb"), "guardrails/r.yml" => File.join(provenance.guardrails_dir, "r.yml"),
      "plugin/plugin.rb" => File.join(provenance.plugin_dir, "plugin.rb"), "scripts/s.sh" => File.join(provenance.scripts_dir, "s.sh") }
  end

  def uninstall(**opts) = Samagotchi::MemoryBundle::Uninstaller.new(name: "demo", **opts).tap(&:run)

  describe "an uninstall" do
    before do
      full_source("1.0.0")
      run_installer
    end

    it "copies each edited hook, rule, plugin and script to the trash, with --force or without" do
      [{}, { force: true }].each do |opts|
        full_source("1.0.0")
        run_installer unless provenance.installed?
        installed_assets.each_value { |path| File.write(path, "edited #{File.basename(path)}\n") }
        un = uninstall(**opts)

        expect(File.exist?(provenance.bundle_dir)).to be false
        saved = Dir.glob(File.join(un.trash_dir, "**", "*")).select { |f| File.file?(f) }.to_h { |f| [f.delete_prefix("#{un.trash_dir}/"), File.read(f)] }
        expect(saved).to include(installed_assets.to_h { |label, path| [label, "edited #{File.basename(path)}\n"] })
      end
    end

    it "copies nothing for unedited ones" do
      expect(uninstall.trash_copy_line).to be_nil
      expect(trash_files.keys).to eq(["a.md"])
    end

    it "names what it saved in chi bundle uninstall's output" do
      File.write(installed_assets["scripts/s.sh"], "edited\n")
      out = StringIO.new
      code = Samagotchi::BundleCommand.new(%w[uninstall demo], stdin: StringIO.new, stdout: out, stderr: StringIO.new).run

      expect(code).to eq(0)
      expect(out.string).to match(%r{^Copied to the trash first: scripts/s\.sh \(.*/\.trash/demo-\d{8}-\d{6}\)$})
    end

    it "copies nothing when an edited memory blocks it" do
      File.write(target, "edited\n")
      File.write(installed_assets["hooks/h.rb"], "edited\n")

      expect { uninstall }.to raise_error(Samagotchi::MemoryBundle::Uninstaller::UninstallError)
      expect(trash_files).to be_empty
      expect(File.read(installed_assets["hooks/h.rb"])).to eq("edited\n")
    end

    it "copies an edit from a bundle with no memories and no hooks, which goes by a shorter path" do
      uninstall
      write_source("1.0.0", {})
      FileUtils.mkdir_p(File.join(source, "guardrails"))
      File.write(File.join(source, "guardrails", "r.yml"), "# rule\n")
      run_installer
      File.write(installed_assets["guardrails/r.yml"], "edited\n")
      un = uninstall

      expect(File.read(File.join(un.trash_dir, "guardrails", "r.yml"))).to eq("edited\n")
      expect(un.trash_copy_line).to include("guardrails/r.yml")
    end

    it "copies a dev install's links never, and leaves their source alone" do
      uninstall
      full_source("1.0.0")
      run_installer(dev: true)
      expect(File.symlink?(installed_assets["hooks/h.rb"])).to be true
      un = uninstall

      expect(un.trash_copy_line).to be_nil
      expect(File.read(File.join(source, "hooks", "h.rb"))).to eq("# hook 1.0.0\n")
    end
  end

  describe "nested files in an asset folder" do
    before do
      full_source("1.0.0")
      run_installer
      %w[guardrails plugin scripts].each do |kind|
        FileUtils.mkdir_p(File.join(provenance.bundle_dir, kind, "sub"))
        File.write(File.join(provenance.bundle_dir, kind, "sub", "mine.txt"), "my #{kind}\n")
      end
    end

    let(:nested) { %w[guardrails plugin scripts].to_h { |kind| ["#{kind}/sub/mine.txt", "my #{kind}\n"] } }

    it "are copied with their relative path before an upgrade removes them" do
      up = run_installer(full_source("2.0.0"), upgrade: true)

      expect(trash_files).to eq(nested)
      expect(up.summary).to include("scripts/sub/mine.txt")
    end

    it "are copied before an uninstall removes them" do
      FileUtils.mkdir_p(File.join(provenance.hooks_dir, "sub"))
      File.write(File.join(provenance.hooks_dir, "sub", "mine.txt"), "my hooks\n")
      uninstall

      expect(trash_files).to include(nested.merge("hooks/sub/mine.txt" => "my hooks\n"))
    end

    it "leave out a nested link and what it points at" do
      outside = File.join(tmpdir, "outside")
      FileUtils.mkdir_p(outside)
      File.write(File.join(outside, "x"), "not ours\n")
      File.symlink(File.join(outside, "x"), File.join(provenance.scripts_dir, "sub", "link"))
      File.symlink(outside, File.join(provenance.scripts_dir, "sub", "dirlink"))
      run_installer(full_source("2.0.0"), upgrade: true)

      expect(trash_files).to eq(nested)
      expect(File.read(File.join(outside, "x"))).to eq("not ours\n")
    end
  end

  describe "when an edit can't be saved" do
    let(:trash_root) { File.join(Samagotchi::MemoryPaths.bundles_dir, ".trash") }
    let(:plugin) { File.join(provenance.plugin_dir, "plugin.rb") }

    before do
      full_source("1.0.0")
      run_installer
      File.write(plugin, "edited\n")
    end

    after { File.chmod(0o644, plugin) if File.exist?(plugin) }

    def upgrade_via_command(*flags)
      out = StringIO.new
      err = StringIO.new
      code = Samagotchi::BundleCommand.new(["upgrade", source, *flags], stdin: StringIO.new, stdout: out, stderr: err).run
      [code, out.string, err.string]
    end

    it "fails cleanly when .trash is a file, naming it, and a retry heals" do
      File.write(trash_root, "in the way\n")
      full_source("2.0.0")
      code, _out, err = upgrade_via_command

      expect(code).to eq(1)
      expect(err).to start_with("Upgrade failed: ").and include(".trash", "nothing was lost")
      expect(File.read(plugin)).to eq("edited\n")
      expect(provenance.read[:version]).to eq("1.0.0")

      FileUtils.rm_f(trash_root)
      expect(upgrade_via_command.first).to eq(0)
      expect(trash_files).to eq("plugin/plugin.rb" => "edited\n")
      expect(File.read(plugin)).to eq("# plugin 2.0.0\n")
      expect(provenance.read[:version]).to eq("2.0.0")
    end

    it "fails cleanly on an edited file it can't read, naming it, and a retry heals" do
      skip "root reads anything" if Process.uid.zero?
      File.chmod(0o000, plugin)
      full_source("2.0.0")
      code, _out, err = upgrade_via_command

      expect(code).to eq(1)
      expect(err).to start_with("Upgrade failed: ").and include("plugin.rb", "nothing was lost")
      File.chmod(0o644, plugin)
      expect(File.read(plugin)).to eq("edited\n")

      expect(upgrade_via_command.first).to eq(0)
      expect(trash_files).to eq("plugin/plugin.rb" => "edited\n")
      expect(provenance.read[:version]).to eq("2.0.0")
    end

    it "fails cleanly on --force over a memory when .trash is a file" do
      File.write(target, "edited\n")
      File.write(trash_root, "in the way\n")
      full_source("2.0.0")
      code, _out, err = upgrade_via_command("--force")

      expect(code).to eq(1)
      expect(err).to include(".trash", "nothing was lost")
      expect(File.read(target)).to eq("edited\n")
    end

    it "refuses an uninstall the same way, removing nothing, and a retry heals" do
      File.write(trash_root, "in the way\n")
      out = StringIO.new
      err = StringIO.new
      code = Samagotchi::BundleCommand.new(%w[uninstall demo], stdin: StringIO.new, stdout: out, stderr: err).run

      expect(code).to eq(1)
      expect(err.string).to start_with("Uninstall failed: ").and include(".trash", "nothing was lost")
      expect(File.read(plugin)).to eq("edited\n")
      expect(File.read(target)).to eq("same\n")
      expect(provenance).to be_installed

      FileUtils.rm_f(trash_root)
      uninstall
      expect(trash_files).to eq("a.md" => "same\n", "plugin/plugin.rb" => "edited\n")
    end
  end
end
