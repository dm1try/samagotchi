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
end
