# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/profile"

RSpec.describe Samagotchi::MemoryBundle::Profile do
  let(:tmp) { Dir.mktmpdir("profile") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  # A shipped dir as a gem lays it out, so a member's source is "shipped".
  let(:shipped) { File.join(tmp, "gem", "lib", "samagotchi", "bundles") }
  let(:prov) { Samagotchi::MemoryBundle::Provenance }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  after do
    FileUtils.remove_entry(tmp)
  end

  # A plain shipped bundle with one memory file <name>.md.
  def ship(name, version: "0.1.0", requires_chi: nil, broken: false)
    dir = File.join(shipped, name)
    FileUtils.mkdir_p(dir)
    body = "# #{name}\n"
    File.write(File.join(dir, "#{name}.md"), body)
    data = { "name" => name, "version" => version, "scope" => "system",
             "files" => { "#{name}.md" => "sha256:#{Digest::SHA256.hexdigest(body)}" } }
    data["requires_chi"] = requires_chi if requires_chi
    data["plugin"] = { "file" => "missing.rb", "sha256" => "" } if broken
    File.write(File.join(dir, "manifest.yml"), YAML.dump(data))
    dir
  end

  def ship_meta(name, includes, version: "0.1.0", dir: shipped)
    path = File.join(dir, name)
    FileUtils.mkdir_p(path)
    File.write(File.join(path, "manifest.yml"),
               YAML.dump("name" => name, "version" => version, "scope" => "system", "includes" => includes))
    path
  end

  def install(dir, **opts) = described_class.install(dir, shipped_dir: shipped, chi_version: "1.0.0", **opts)
  def installed = prov.each_installed.map { |name, _| name }
  def recorded(name) = prov.new(name: name).read[:includes]
  def plain_install(dir) = Samagotchi::MemoryBundle::Installer.new(source: dir, name: File.basename(dir), scope: "system").run

  describe ".shipped_meta?" do
    it "is true only for a meta in the shipped dir: includes: from anywhere else is ignored" do
      ship("a")
      expect(described_class.shipped_meta?(ship_meta("core", ["a"]), shipped_dir: shipped)).to be(true)
      expect(described_class.shipped_meta?(File.join(shipped, "a"), shipped_dir: shipped)).to be(false)
      elsewhere = ship_meta("core", ["a"], dir: File.join(tmp, "downloads"))
      expect(described_class.shipped_meta?(elsewhere, shipped_dir: shipped)).to be(false)
      expect(described_class.shipped_meta?(File.join(tmp, "nothing"), shipped_dir: shipped)).to be(false)
    end
  end

  describe ".install" do
    it "installs the members that aren't installed and records them all, a hand-installed one without reinstalling it" do
      %w[a b c].each { |n| ship(n) }
      core = ship_meta("core", %w[a b c])
      plain_install(File.join(shipped, "b"))
      b_manifest = File.join(system_dir, ".bundles", "b", "manifest.json")
      before = File.read(b_manifest)

      result = install(core)

      expect(result).to have_attributes(name: "core", version: "0.1.0", installed: %w[a c], already: %w[b], skipped: {}, failed: {})
      expect(installed).to eq(%w[a b c core])
      expect(File.read(b_manifest)).to eq(before)
      expect(recorded("core")).to eq(%w[a b c])
      expect(prov.new(name: "core").read).to include(version: "0.1.0", source: core, files: {})
      expect(prov.new(name: "a").read[:source]).to eq(File.join(shipped, "a"))
    end

    it "installs nothing the second time (bootstrap re-runs are idempotent)" do
      %w[a b].each { |n| ship(n) }
      core = ship_meta("core", %w[a b])
      install(core)
      record = File.read(File.join(system_dir, ".bundles", "core", "manifest.json"))

      expect(install(core)).to have_attributes(installed: [], already: [], skipped: {}, failed: {})
      expect(File.read(File.join(system_dir, ".bundles", "core", "manifest.json"))).to eq(record)
      expect(described_class.to_install(Samagotchi::MemoryBundle::Manifest.read(dir: core))).to eq([])
    end

    it "keeps a member the user uninstalled out, and installs only a bundle new to the profile" do
      %w[a b c].each { |n| ship(n) }
      install(ship_meta("core", %w[a b]))
      Samagotchi::MemoryBundle::Uninstaller.new(name: "b").run

      core2 = ship_meta("core", %w[a b c], version: "0.2.0")
      expect(described_class.to_install(Samagotchi::MemoryBundle::Manifest.read(dir: core2))).to eq(%w[c])
      result = install(core2)

      expect(result.installed).to eq(%w[c])
      expect(installed).to eq(%w[a c core])
      expect(recorded("core")).to eq(%w[a b c])
      expect(prov.new(name: "core").read[:version]).to eq("0.2.0")
    end

    it "leaves a name dropped from the profile installed" do
      %w[a b].each { |n| ship(n) }
      install(ship_meta("core", %w[a b]))
      install(ship_meta("core", %w[a], version: "0.2.0"))

      expect(installed).to eq(%w[a b core])
    end

    it "skips a member this chi is too old for and records neither it nor a failed one, so a later run retries them" do
      ship("a")
      ship("new", requires_chi: ">= 2.0")
      ship("bad", broken: true)
      core = ship_meta("core", %w[a new bad])

      result = install(core)

      expect(result.installed).to eq(%w[a])
      expect(result.skipped).to eq("new" => "it requires chi >= 2.0 (this is chi 1.0.0)")
      expect(result.failed.keys).to eq(%w[bad])
      expect(result.failed["bad"]).to include("missing.rb")
      expect(recorded("core")).to eq(%w[a])
      expect(installed).to eq(%w[a core])

      ship("bad")
      again = described_class.install(core, shipped_dir: shipped, chi_version: "2.0.0")
      expect(again.installed).to eq(%w[new bad])
      expect(recorded("core")).to eq(%w[a new bad])
    end

    it "treats an installed meta with no recorded includes as having recorded everything" do
      %w[a b].each { |n| ship(n) }
      core = ship_meta("core", %w[a b])
      prov.new(name: "core").write(files: {}, scope: "system", version: "0.1.0", source_path: core)

      expect(install(core).installed).to eq([])
      expect(installed).to eq(%w[core])
    end

    it "takes members from the shipped dir even when the cwd has a dir of the same name" do
      ship("a")
      core = ship_meta("core", %w[a])
      local = File.join(tmp, "cwd")
      FileUtils.mkdir_p(File.join(local, "a"))
      Dir.chdir(local) { install(core) }

      expect(prov.new(name: "a").read[:source]).to eq(File.join(shipped, "a"))
    end

    it "writes nothing on a dry run" do
      %w[a b].each { |n| ship(n) }
      plain_install(File.join(shipped, "b"))

      result = install(ship_meta("core", %w[a b]), dry_run: true)

      expect(result).to have_attributes(installed: %w[a], already: %w[b])
      expect(installed).to eq(%w[b])
    end
  end

  describe ".uninstall" do
    it "uninstalls the recorded members still installed, then the meta" do
      %w[a b c].each { |n| ship(n) }
      install(ship_meta("core", %w[a b]))
      plain_install(File.join(shipped, "c"))
      Samagotchi::MemoryBundle::Uninstaller.new(name: "b").run

      result = described_class.uninstall("core", shipped_dir: shipped)

      expect(result).to have_attributes(removed: %w[a], blocked: {}, gone: true)
      expect(installed).to eq(%w[c])
    end

    it "passes on a member's warnings" do
      ship("a")
      install(ship_meta("core", %w[a]))
      prov.new(name: "mine").write(files: { "a.md" => File.join(system_dir, "a.md") }, scope: "system", version: "1", source_path: "/x")

      result = described_class.uninstall("core", shipped_dir: shipped)
      expect(result.warnings).to eq(["a: Kept a.md: bundle mine has it too"])
      expect(File.exist?(File.join(system_dir, "a.md"))).to be true
    end

    it "carries on past a member with an edited file, reports it and keeps the meta; --force removes it" do
      %w[a b].each { |n| ship(n) }
      install(ship_meta("core", %w[a b]))
      File.write(File.join(system_dir, "a.md"), "# mine\n")

      result = described_class.uninstall("core", shipped_dir: shipped)

      expect(result.removed).to eq(%w[b])
      expect(result.blocked.keys).to eq(%w[a])
      expect(result.blocked["a"]).to include("local edits")
      expect(result.gone).to be(false)
      expect(installed).to eq(%w[a core])

      forced = described_class.uninstall("core", shipped_dir: shipped, force: true)
      expect(forced).to have_attributes(removed: %w[a], blocked: {}, gone: true)
      files, dir = forced.trash["a"]
      expect(files).to eq(["a.md"])
      expect(File.read(File.join(dir, "a.md"))).to eq("# mine\n")
      expect(installed).to eq([])
    end
  end

  describe ".installed_meta?" do
    it "knows a meta by its recorded includes, or by a shipped source whose manifest is a meta" do
      ship("a")
      core = ship_meta("core", %w[a])
      expect(described_class.installed_meta?("core", { includes: [] }, shipped_dir: shipped)).to be(true)
      expect(described_class.installed_meta?("core", { source: core }, shipped_dir: shipped)).to be(true)
      expect(described_class.installed_meta?("core", { source: "/tmp/core" }, shipped_dir: shipped)).to be(false)
      expect(described_class.installed_meta?("a", { source: File.join(shipped, "a") }, shipped_dir: shipped)).to be(false)
    end
  end
end
