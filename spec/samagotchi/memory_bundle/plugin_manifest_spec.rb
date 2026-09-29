# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"

require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/builder"
require "samagotchi/memory_bundle/status"
require "samagotchi/plugin/loader"

RSpec.describe "Bundle plugin: manifest, install, provenance, status, build" do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-plugin-manifest-") }
  let(:system_dir) { File.join(tmpdir, "memories") }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:plugin_source) { "class Plugin\n  def register(chi); end\nend\n" }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = bundles_dir
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  def write_source(plugin: { "file" => "plugin.rb" }, requires_chi: nil, content: plugin_source, sha: :real)
    src = File.join(tmpdir, "src-#{rand(100_000)}")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "identity.md"), "# Id\n")
    manifest = { "name" => "plug", "version" => "1.0.0",
                 "files" => { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Id\n")}" } }
    if plugin
      File.write(File.join(src, plugin["file"]), content) if content
      plugin = plugin.merge("sha256" => "sha256:#{Digest::SHA256.hexdigest(content.to_s)}") if sha == :real
      plugin = plugin.merge("sha256" => "sha256:#{"0" * 64}") if sha == :wrong
      manifest["plugin"] = plugin
    end
    manifest["requires_chi"] = requires_chi if requires_chi
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  def install(src, **opts)
    installer = Samagotchi::MemoryBundle::Installer.new(source: src, name: "plug", scope: "system", strict: true, **opts)
    installer.run
    installer
  end

  let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "plug") }

  describe Samagotchi::MemoryBundle::Manifest do
    it "reads plugin: {file:, sha256:} and requires_chi:" do
      manifest = described_class.read(dir: write_source(requires_chi: ">= 0.1.0"))
      expect(manifest.plugin).to eq(file: "plugin.rb", sha256: "sha256:#{Digest::SHA256.hexdigest(plugin_source)}")
      expect(manifest.checksum_for_plugin).to eq(Digest::SHA256.hexdigest(plugin_source))
      expect(manifest.requires_chi).to eq(">= 0.1.0")
    end

    it "has no plugin when the manifest names none" do
      manifest = described_class.read(dir: write_source(plugin: nil))
      expect(manifest.plugin).to be_nil
      expect(manifest.requires_chi).to be_nil
    end

    it "refuses a plugin file outside the bundle's top directory" do
      src = write_source(plugin: { "file" => "../evil.rb" }, content: nil)
      expect { described_class.read(dir: src) }.to raise_error(described_class::ValidationError, /top directory/)
    end

    it "tells why a chi version doesn't meet requires_chi" do
      expect(described_class.requires_chi_failure(nil, "0.1.28")).to be_nil
      expect(described_class.requires_chi_failure(">= 0.1.20", "0.1.28")).to be_nil
      expect(described_class.requires_chi_failure(">= 0.1.20, < 0.2", "0.1.28")).to be_nil
      expect(described_class.requires_chi_failure(">= 9.0", "0.1.28")).to eq("it requires chi >= 9.0 (this is chi 0.1.28)")
      expect(described_class.requires_chi_failure("soon", "0.1.28")).to match(/not a version requirement/)
    end

    it "writes plugin: and requires_chi: back" do
      dir = File.join(tmpdir, "out")
      described_class.write(dir: dir, name: "plug", version: "1.0.0", files: {},
                            plugin: { file: "plugin.rb", sha256: "abc" }, requires_chi: ">= 0.1")
      data = YAML.load_file(File.join(dir, "manifest.yml"))
      expect(data["plugin"]).to eq("file" => "plugin.rb", "sha256" => "sha256:abc")
      expect(data["requires_chi"]).to eq(">= 0.1")
    end
  end

  describe "install" do
    it "copies the plugin into plugin/ and records its sha256, requires_chi and a base" do
      installer = install(write_source(requires_chi: ">= 0.1.0"))
      path = File.join(bundles_dir, "plug", "plugin", "plugin.rb")
      expect(File.read(path)).to eq(plugin_source)
      data = provenance.read
      expect(data[:plugin]).to eq(file: "plugin.rb", sha256: "sha256:#{Digest::SHA256.hexdigest(plugin_source)}")
      expect(data[:requires_chi]).to eq(">= 0.1.0")
      expect(provenance.plugin_path).to eq(path)
      expect(File.read(provenance.plugin_base_path("plugin.rb"))).to eq(plugin_source)
      expect(installer.results["plugin.rb"][:status]).to eq("installed")
      expect(installer.warnings).to be_empty
    end

    it "fails when the manifest names a plugin the bundle doesn't have" do
      src = write_source(content: nil)
      expect { install(src) }.to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /doesn't have/)
    end

    it "warns on a declared sha256 that differs, and records the installed file's" do
      installer = install(write_source(sha: :wrong))
      expect(installer.warnings.join).to match(/Checksum mismatch for plugin plugin.rb/)
      expect(provenance.read[:plugin][:sha256]).to eq("sha256:#{Digest::SHA256.hexdigest(plugin_source)}")
    end

    it "warns when this chi doesn't meet requires_chi" do
      installer = install(write_source(requires_chi: ">= 99.0"))
      expect(installer.warnings.join).to match(/won't load: it requires chi >= 99.0/)
    end

    it "removes the plugin when an upgrade drops it" do
      install(write_source)
      install(write_source(plugin: nil), upgrade: true)
      expect(Dir.exist?(provenance.plugin_dir)).to be false
      expect(provenance.read[:plugin]).to be_nil
      expect(provenance.plugin_path).to be_nil
    end

    it "keeps the new plugin loadable when an upgrade keeps an edited .md (conflict)" do
      install(write_source)
      target = File.join(system_dir, "identity.md")
      File.write(target, "# Id\nmy note\n")
      newer = "class Plugin\n  def register(chi) = :v2\nend\n"
      src = write_source(content: newer)
      File.write(File.join(src, "identity.md"), "# Id v2\n")
      manifest = YAML.load_file(File.join(src, "manifest.yml"))
      manifest["version"] = "2.0.0"
      manifest["files"] = { "identity.md" => "sha256:#{Digest::SHA256.hexdigest("# Id v2\n")}" }
      File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))

      installer = install(src, upgrade: true)

      expect(installer.conflicts.keys).to eq(["identity.md"])
      expect(File.read(target)).to eq("# Id\nmy note\n")
      data = provenance.read
      expect(data[:version]).to eq("2.0.0")
      expect(Samagotchi::Plugin::Loader.unloadable_reason(provenance.plugin_path(data), data)).to be_nil
      expect(data[:files][:"identity.md"]).to include(conflict: true)
      expect(File.read(provenance.base_path("identity.md"))).to eq("# Id\n")
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:files]["identity.md"]).to include(conflict: true)
    end

    it "lists it among the installed bundles with a plugin" do
      install(write_source)
      expect(Samagotchi::MemoryBundle::Provenance.each_installed_with_plugin.to_a.map(&:first)).to eq(["plug"])
    end

    it "is removed with the bundle" do
      install(write_source)
      uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "plug", force: true)
      uninstaller.run
      expect(uninstaller.removed_files).to include("plugin/plugin.rb")
      expect(Dir.exist?(File.join(bundles_dir, "plug"))).to be false
    end
  end

  describe "status" do
    it "says ok, modified or missing" do
      install(write_source)
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:plugin]).to include(file: "plugin.rb", state: "ok")
      File.write(provenance.plugin_path, "# edited\n")
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:plugin][:state]).to eq("modified")
      File.delete(provenance.plugin_path)
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:plugin][:state]).to eq("missing")
    end

    it "carries a requires_chi failure" do
      install(write_source(requires_chi: ">= 99.0"))
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:plugin][:requires_failure]).to match(/requires chi >= 99.0/)
    end

    it "has no plugin entry without one" do
      install(write_source(plugin: nil))
      expect(Samagotchi::MemoryBundle::Status.bundle_status("plug")[:plugin]).to be_nil
    end
  end

  describe "build" do
    it "puts the installed plugin and requires_chi into the built bundle" do
      install(write_source(requires_chi: ">= 0.1.0"))
      out = File.join(tmpdir, "built")
      Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "plug", out: out).run
      expect(File.read(File.join(out, "plugin.rb"))).to eq(plugin_source)
      manifest = Samagotchi::MemoryBundle::Manifest.read(dir: out)
      expect(manifest.plugin).to eq(file: "plugin.rb", sha256: "sha256:#{Digest::SHA256.hexdigest(plugin_source)}")
      expect(manifest.requires_chi).to eq(">= 0.1.0")
    end
  end
end
