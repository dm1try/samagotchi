# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"
require "samagotchi/memory_bundle/shipped_update"
require "samagotchi/plugin/loader"

RSpec.describe Samagotchi::MemoryBundle::ShippedUpdate do
  let(:tmp) { Dir.mktmpdir("shipped-update") }
  let(:system_dir) { File.join(tmp, "memories") }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(system_dir, ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmp, "proj")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.remove_entry(tmp)
  end

  # A copy of a shipped bundle as an older gem shipped it: under
  # <root>/lib/samagotchi/bundles/<dir>, at +version+, each .md replaced
  # by +md+ (so the shipped one differs).
  def old_copy(dir, version: "0.0.1", md: nil, root: File.join(tmp, "gems", "samagotchi-0.0.1"), manifest: {})
    dest = File.join(root, "lib", "samagotchi", "bundles", dir)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, dir), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml"))
    data["version"] = version
    if md
      (data["files"] || {}).each_key do |key|
        File.write(File.join(dest, key), md)
        data["files"][key] = "sha256:#{Digest::SHA256.hexdigest(md)}"
      end
    end
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data.merge(manifest)))
    dest
  end

  def install(source, name)
    Samagotchi::MemoryBundle::Installer.new(source: source, name: name, scope: "system", strict: true).run
  end

  def version_of(name) = Samagotchi::MemoryBundle::Provenance.new(name: name).read[:version]
  def shipped_version(dir) = YAML.load_file(File.join(shipped, dir, "manifest.yml"))["version"]

  def plugin_loads?(name)
    data = Samagotchi::MemoryBundle::Provenance.new(name: name).read
    Samagotchi::Plugin::Loader.unloadable_reason(Samagotchi::MemoryBundle::Provenance.new(name: name).plugin_path(data), data).nil?
  end

  def mtimes
    Dir.glob(File.join(system_dir, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) }.to_h { |f| [f, File.mtime(f)] }
  end

  it "updates an older bundle installed from chi; the plugin loads, and a second pass changes nothing" do
    install(old_copy("btw"), "btw")

    rows = described_class.plan
    expect(rows.map { |r| [r.name, r.from, r.to, r.status] }).to eq([["btw", "0.0.1", shipped_version("btw"), :would_update]])

    applied = described_class.apply(rows)
    expect(applied.first).to have_attributes(status: :updated, kept: [])
    expect(version_of("btw")).to eq(shipped_version("btw"))
    expect(Samagotchi::MemoryBundle::Provenance.new(name: "btw").read[:source]).to eq(File.join(shipped, "btw"))
    expect(plugin_loads?("btw")).to be(true)

    before = mtimes
    again = described_class.apply(described_class.plan)
    expect(again.map { |r| [r.name, r.status] }).to eq([["btw", :up_to_date]])
    expect(mtimes).to eq(before)
  end

  it "keeps an edited .md that conflicts, and the hook still loads (its sha is recorded)" do
    install(old_copy("known-names", md: "old words\n"), "known-names")
    File.write(File.join(system_dir, "known_names.md"), "old words\nmy note\n")

    rows = described_class.plan
    expect(rows.first).to have_attributes(status: :would_update, kept: ["known_names.md"])

    row = described_class.apply(rows).first
    expect(row).to have_attributes(status: :updated, kept: ["known_names.md"])
    expect(File.read(File.join(system_dir, "known_names.md"))).to eq("old words\nmy note\n")
    data = Samagotchi::MemoryBundle::Provenance.new(name: "known-names").read
    expect(data[:version]).to eq(shipped_version("known-names"))
    hook = File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb")
    expect("sha256:#{Digest::SHA256.hexdigest(File.read(hook))}").to eq(data[:hooks][:"known_names.rb"][:sha256])
    expect(described_class.plan.first.status).to eq(:up_to_date)
  end

  it "reports an edited hook it replaces" do
    install(old_copy("known-names"), "known-names")
    File.write(File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb"), "# mine\n")

    row = described_class.apply(described_class.plan).first
    expect(row).to have_attributes(status: :updated, replaced: ["hooks/known_names.rb"])
    expect(File.read(File.join(shipped, "known-names", "hooks", "known_names.rb")))
      .to eq(File.read(File.join(Samagotchi::MemoryBundle::Provenance.new(name: "known-names").hooks_dir, "known_names.rb")))
  end

  it "reports an edited plugin as replaced" do
    install(old_copy("btw"), "btw")
    File.write(Samagotchi::MemoryBundle::Provenance.new(name: "btw").plugin_path, "# mine\n")
    expect(described_class.plan.first.replaced).to eq(["plugin/plugin.rb"])
  end

  it "skips a same-named bundle that wasn't installed from chi" do
    zipped = File.join(tmp, "unpacked-btw")
    FileUtils.cp_r(old_copy("btw"), zipped)
    install(zipped, "btw")
    expect(described_class.plan.first).to have_attributes(status: :skipped, note: "not from chi", to: nil)
  end

  it "skips a user bundle chi doesn't ship" do
    install(old_copy("btw", manifest: { "name" => "mine" }), "mine")
    expect(described_class.plan.first).to have_attributes(name: "mine", status: :skipped, note: "not from chi")
  end

  it "leaves an installed version newer than the shipped one" do
    install(old_copy("btw", version: "99.0.0"), "btw")
    expect(described_class.plan.first).to have_attributes(status: :skipped, note: "newer than shipped: left")
  end

  it "skips a shipped bundle this chi can't load" do
    install(old_copy("btw"), "btw")
    newer = File.join(tmp, "new")
    root = File.join(newer, "lib", "samagotchi", "bundles")
    FileUtils.mkdir_p(root)
    FileUtils.cp_r(File.join(shipped, "btw"), root)
    data = YAML.load_file(File.join(root, "btw", "manifest.yml")).merge("version" => "0.9.0", "requires_chi" => ">= 99.0")
    File.write(File.join(root, "btw", "manifest.yml"), YAML.dump(data))

    row = described_class.plan(shipped_dir: root).first
    expect(row).to have_attributes(status: :skipped, note: "needs chi >= 99.0", to: "0.9.0")
    expect(described_class.apply([row]).first.status).to eq(:skipped)
    expect(version_of("btw")).to eq("0.0.1")
  end

  it "skips a bundle whose provenance manifest.json doesn't parse" do
    dir = File.join(system_dir, ".bundles", "broken")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), "{bad")
    expect(described_class.plan.map { |r| [r.name, r.status, r.note] }).to eq([["broken", :skipped, "manifest.json unreadable"]])
  end

  it "leaves the system bundle to SystemBundle and lists shipped bundles that aren't installed" do
    install(old_copy("system"), "samagotchi-system")
    install(old_copy("btw"), "btw")
    expect(described_class.plan.map(&:name)).to eq(["btw"])
    expect(described_class.not_installed.map(&:name)).not_to include("btw", "samagotchi-system")
    expect(described_class.not_installed.map(&:name)).to include("known-names")
  end

  it "fails one row without stopping the rest" do
    install(old_copy("btw"), "btw")
    install(old_copy("known-names"), "known-names")
    rows = described_class.plan
    rows.first.source_dir = File.join(tmp, "gone")

    applied = described_class.apply(rows)
    expect(applied.map(&:status)).to eq(%i[failed updated])
    expect(applied.first.note).to match(/does not exist/)
  end
end
