# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "digest"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/builder"

RSpec.describe Samagotchi::MemoryBundle::Uninstaller do
  let(:tmpdir) { Dir.mktmpdir("uninstaller-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle_with_hooks(files = {}, hooks = {}, name: "test-bundle", version: "1.0.0")
    src = File.join(tmpdir, "src_#{name}_#{rand(1000)}")
    FileUtils.mkdir_p(src)
    FileUtils.mkdir_p(File.join(src, "hooks"))
    files.each { |k, v| File.write(File.join(src, k), v) }
    hooks.each { |k, v| File.write(File.join(src, "hooks", k), v) }
    manifest = { "name" => name, "version" => version, "files" => {}, "hooks" => {} }
    files.each { |k, v| manifest["files"][k] = "sha256:#{Digest::SHA256.hexdigest(v)}" }
    hooks.each { |k, v| manifest["hooks"][k] = { "sha256" => "sha256:#{Digest::SHA256.hexdigest(v)}", "event" => "before_tool_call", "on_error" => "skip" } }
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  def install_bundle(src, name)
    inst = Samagotchi::MemoryBundle::Installer.new(source: src, name: name, scope: "system", force: false, strict: true)
    inst.run
  end

  it "removes hook files and dir" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, name: "hook-uninstall")
    install_bundle(src, "hook-uninstall")
    expect(File.exist?(File.join(bundles_dir, "hook-uninstall", "hooks", "guardrails.rb"))).to be true
    uninstaller = described_class.new(name: "hook-uninstall", force: false)
    uninstaller.run
    expect(File.exist?(File.join(bundles_dir, "hook-uninstall", "hooks", "guardrails.rb"))).to be false
    expect(Dir.exist?(File.join(bundles_dir, "hook-uninstall"))).to be false
    expect(uninstaller.removed_files).to include("hooks/guardrails.rb")
  end

  it "removes the entry's index line, including a legacy name.md line" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "index-uninstall")
    install_bundle(src, "index-uninstall")
    index_path = File.join(system_dir, "index.md")
    File.write(index_path, File.read(index_path) + "- **identity.md** · system · 2026-09-09 · 310\n- **notes** · system · 2026-09-01 · 5\n")

    described_class.new(name: "index-uninstall", force: false).run

    index_content = File.read(index_path)
    expect(index_content).not_to include("**identity**")
    expect(index_content).not_to include("**identity.md**")
    expect(index_content).to include("- **notes** ·")
  end

  describe "the trash" do
    let(:trash_root) { File.join(bundles_dir, ".trash") }

    it "moves the bundle's memory files into .bundles/.trash/<name>-<time>/ instead of deleting them" do
      src = write_bundle_with_hooks({ "notes.md" => "# Notes\n" }, { "g.rb" => "class G; def call(e); end; end" }, name: "trash-me")
      install_bundle(src, "trash-me")

      uninstaller = described_class.new(name: "trash-me", force: false)
      uninstaller.run

      expect(File.exist?(File.join(system_dir, "notes.md"))).to be false
      expect(uninstaller.trash_dir).to match(%r{\A#{Regexp.escape(trash_root)}/trash-me-\d{8}-\d{6}\z})
      expect(File.read(File.join(uninstaller.trash_dir, "notes.md"))).to eq("# Notes\n")
      expect(uninstaller.trashed_files).to eq(["notes.md"])
      expect(uninstaller.removed_files).to eq(["hooks/g.rb"])
      expect(File.read(File.join(system_dir, "index.md"))).not_to include("**notes**")
    end

    it "moves an edited file there too with --force" do
      src = write_bundle_with_hooks({ "notes.md" => "# Notes\n" }, {}, name: "trash-forced")
      install_bundle(src, "trash-forced")
      File.write(File.join(system_dir, "notes.md"), "# Notes\nmine\n")

      uninstaller = described_class.new(name: "trash-forced", force: true)
      uninstaller.run
      expect(File.read(File.join(uninstaller.trash_dir, "notes.md"))).to eq("# Notes\nmine\n")
    end

    it "gives two uninstalls in the same second their own dirs" do
      now = Time.new(2026, 10, 3, 12, 0, 0)
      allow(Time).to receive(:now).and_return(now)
      dirs = 2.times.map do
        install_bundle(write_bundle_with_hooks({ "notes.md" => "# Notes\n" }, {}, name: "twice"), "twice")
        described_class.new(name: "twice").tap(&:run).trash_dir
      end
      expect(dirs.map { |d| File.basename(d) }).to eq(%w[twice-20261003-120000 twice-20261003-120000-2])
    end

    it "makes no trash dir when there is nothing to move" do
      src = write_bundle_with_hooks({ "notes.md" => "# Notes\n" }, {}, name: "gone-already")
      install_bundle(src, "gone-already")
      File.delete(File.join(system_dir, "notes.md"))

      uninstaller = described_class.new(name: "gone-already")
      uninstaller.run
      expect(uninstaller.trash_dir).to be_nil
      expect(Dir.exist?(trash_root)).to be false
    end

    it "is never read as an installed bundle" do
      src = write_bundle_with_hooks({ "notes.md" => "# Notes\n" }, {}, name: "hidden")
      install_bundle(src, "hidden")
      described_class.new(name: "hidden").run
      expect(Samagotchi::MemoryBundle::Provenance.each_installed.map(&:first)).to eq([])
    end
  end

  describe "a memory the user had before the install" do
    it "is left alone: the install skipped it, so uninstall doesn't touch it (a bundle shipping the same name)" do
      File.write(File.join(system_dir, "notes.md"), "# my notes\n")
      src = write_bundle_with_hooks({ "notes.md" => "# their notes\n", "extra.md" => "# Extra\n" }, {}, name: "third-party")
      install_bundle(src, "third-party")

      uninstaller = described_class.new(name: "third-party")
      uninstaller.run

      expect(File.read(File.join(system_dir, "notes.md"))).to eq("# my notes\n")
      expect(uninstaller.trashed_files).to eq(["extra.md"])
      expect(File.read(File.join(system_dir, "index.md"))).to include("- **notes** ·")
    end

    it "is left alone after chi bundle build + install of the user's own memories on the same machine" do
      File.write(File.join(system_dir, "identity.md"), "# me\n")
      File.write(File.join(system_dir, "work.md"), "# work\n")
      out = File.join(tmpdir, "built")
      Samagotchi::MemoryBundle::Builder.new(scope: "system", out: out).run
      install_bundle(out, "chi_system_memories")

      described_class.new(name: "chi_system_memories").run

      expect(File.read(File.join(system_dir, "identity.md"))).to eq("# me\n")
      expect(File.read(File.join(system_dir, "work.md"))).to eq("# work\n")
      expect(Dir.exist?(File.join(bundles_dir, ".trash"))).to be false
    end
  end

  describe "a file another installed bundle has too" do
    before do
      install_bundle(write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "first"), "first")
      # A bundle installed before chi recorded only the files it wrote
      # claims the same file.
      Samagotchi::MemoryBundle::Provenance.new(name: "legacy").write(
        files: { "identity.md" => File.join(system_dir, "identity.md") }, scope: "system", version: "1.0.0", source_path: "/gone"
      )
    end

    it "stays (with its index line) while the other bundle is installed, then goes with the last one" do
      Samagotchi::MemoryBundle::IndexUpdater.update_index("system", "identity", 5, nil, source: "legacy")
      uninstaller = described_class.new(name: "legacy")
      uninstaller.run

      expect(File.read(File.join(system_dir, "identity.md"))).to eq("# Id\n")
      expect(uninstaller.trashed_files).to eq([])
      expect(uninstaller.warnings).to eq(["Kept identity.md: bundle first has it too"])
      expect(File.read(File.join(system_dir, "index.md"))).to include("- **identity** · system · #{Date.today.iso8601} · 5 · from first\n")

      described_class.new(name: "first").run
      expect(File.exist?(File.join(system_dir, "identity.md"))).to be false
    end

    it "doesn't block the uninstall when edited: it isn't removed" do
      File.write(File.join(system_dir, "identity.md"), "# Id\nmine\n")
      expect { described_class.new(name: "legacy").run }.not_to raise_error
      expect(File.read(File.join(system_dir, "identity.md"))).to eq("# Id\nmine\n")
    end

    it "only counts a bundle of the same scope" do
      Samagotchi::MemoryBundle::Provenance.new(name: "first").write(
        files: { "identity.md" => File.join(system_dir, "identity.md") }, scope: "project", version: "1.0.0", source_path: "/x"
      )
      described_class.new(name: "legacy").run
      expect(File.exist?(File.join(system_dir, "identity.md"))).to be false
    end
  end

  it "says when an index line couldn't be removed, and uninstalls anyway" do
    install_bundle(write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "idx"), "idx")
    allow(Samagotchi::MemoryBundle::IndexUpdater).to receive(:remove_index).and_raise(Errno::EACCES, "index.md")

    uninstaller = described_class.new(name: "idx")
    uninstaller.run
    expect(uninstaller.trashed_files).to eq(["identity.md"])
    expect(uninstaller.warnings).to eq(["index.md: line for identity not removed (Permission denied - index.md)"])
  end

  it "memory-only bundles unaffected" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "no-hook")
    install_bundle(src, "no-hook")
    uninstaller = described_class.new(name: "no-hook", force: false)
    expect { uninstaller.run }.not_to raise_error
    expect(uninstaller.trashed_files).to include("identity.md")
  end

  it "removes provenance bundle_dir even when hooks present" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, { "a.rb" => "class A; def call(e); end; end", "b.rb" => "class B; def call(e); end; end" }, name: "multi-hook")
    install_bundle(src, "multi-hook")
    described_class.new(name: "multi-hook", force: false).run
    expect(Dir.exist?(File.join(bundles_dir, "multi-hook"))).to be false
  end

  it "keeps a shared model overlay without giving it an index line" do
    files = { "tips.md" => "Base\n", "tips.qwen3.md" => "Qwen\n" }
    install_bundle(write_bundle_with_hooks(files, name: "ovl-b"), "ovl-b")
    # A legacy bundle (it recorded every file) claims the same two.
    Samagotchi::MemoryBundle::Provenance.new(name: "ovl-a").write(
      files: files.keys.to_h { |f| [f, File.join(system_dir, f)] }, scope: "system", version: "1.0.0", source_path: "/gone"
    )

    uninstaller = described_class.new(name: "ovl-a")
    uninstaller.run
    expect(File.exist?(File.join(system_dir, "tips.qwen3.md"))).to be true
    index = File.read(File.join(system_dir, "index.md"))
    expect(index).to include("- **tips** · system")
    expect(index).to include("from ovl-b")
    expect(index).not_to include("tips.qwen3")
  end
end
