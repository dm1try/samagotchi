# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "stringio"

require "samagotchi/bundle_command"
require "samagotchi/terminal_ui"
require "samagotchi/memory_bundle/installer"

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
      FileUtils.mkdir_p(File.join(source, "hooks"))
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
end
