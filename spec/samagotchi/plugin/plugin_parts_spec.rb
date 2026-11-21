# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "samagotchi/plugin/loader"
require "samagotchi/commands/registry"
require "samagotchi/tools/registry"
require "samagotchi/hooks/registry"
require "samagotchi/guardrails/load_failures"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/builder"
require "samagotchi/memory_bundle/status"
require "samagotchi/memory_bundle/shas"
require "samagotchi/session_config"

# A plugin in several files (manifest plugin: parts:): installed beside the
# plugin file, recorded under the record's plugin, each checked at load and
# evaluated, in the listed order, into the same fresh module.
RSpec.describe "plugin parts (plugin: parts:)" do
  let(:tmpdir) { Dir.mktmpdir("plugin-parts-") }
  let(:fixture) { File.expand_path("../../fixtures/plugin_parts_bundle", __dir__) }
  let(:bundles_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles") }
  let(:plugin_dir) { File.join(bundles_dir, "plugin-parts", "plugin") }
  let(:installed) { Samagotchi::InstalledBundles::Dir.new(name: "plugin-parts") }
  let(:registries) do
    Samagotchi::Plugin::Registries.new(commands: Samagotchi::Commands::Registry.new, tools: Samagotchi::Tools::Registry.new,
                                       hooks: Samagotchi::Hooks::Registry.new, services: Samagotchi::Plugin::Services.new)
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before { FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  # A copy of the fixture bundle to change.
  def source
    @source ||= File.join(tmpdir, "src").tap { |dir| FileUtils.cp_r(fixture, dir) }
  end

  def install(src = source, **opts)
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "plugin-parts", scope: "system", strict: true, **opts).tap(&:run)
  end

  def manifest_of(src) = YAML.load_file(File.join(src, "manifest.yml"))

  def write_manifest(src, manifest) = File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))

  def record = installed.record

  def load_plugin(failures = Samagotchi::Guardrails::LoadFailures.new)
    ok = Samagotchi::Plugin::Loader.load_bundle("plugin-parts", record, registries, failures: failures)
    [ok, failures]
  end

  def parts_command = registries.commands.lookup("/parts").handler.call("")

  describe "install" do
    it "puts every part beside the plugin file and records them in their order, with a base each" do
      install
      expect(Dir.children(plugin_dir).sort).to eq(%w[helpers.rb plugin.rb shout.rb])
      plugin = JSON.parse(File.read(File.join(bundles_dir, "plugin-parts", "manifest.json")))["plugin"]
      expect(plugin["parts"].keys).to eq(%w[helpers.rb shout.rb])
      expect(plugin["parts"]["shout.rb"]).to eq(Samagotchi::InstalledBundles::FileDigest.sha256(File.join(fixture, "shout.rb")))
      expect(record.plugin.parts.keys).to eq(%w[helpers.rb shout.rb])
      expect(record.plugin_shas.keys).to eq(%w[helpers.rb shout.rb plugin.rb])
      expect(installed.plugin_part_paths).to eq(%w[helpers.rb shout.rb].map { |part| File.join(plugin_dir, part) })
      expect(File.read(File.join(bundles_dir, "plugin-parts", "bases", "plugin", "shout.rb"))).to eq(File.read(File.join(fixture, "shout.rb")))
    end

    it "refuses a part the bundle doesn't have, before writing anything" do
      FileUtils.rm(File.join(source, "shout.rb"))
      expect { install }.to raise_error(Samagotchi::MemoryBundle::Installer::InstallError,
                                        "the manifest names plugin part shout.rb, which the bundle doesn't have")
      expect(File.exist?(File.join(bundles_dir, "plugin-parts"))).to be false
    end

    it "refuses a part whose sha differs from the manifest's, and --force installs it with the warning" do
      File.write(File.join(source, "shout.rb"), "#{File.read(File.join(source, "shout.rb"))}# edited\n")
      expect { install(refuse_mismatch: true) }
        .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, /Checksum mismatch for plugin part shout\.rb/)
      warnings = install(refuse_mismatch: true, force: true).warnings
      expect(warnings.join("\n")).to include("Checksum mismatch for plugin part shout.rb")
      expect(File.read(File.join(plugin_dir, "shout.rb"))).to end_with("# edited\n")
    end

    it "links each part in a dev install" do
      install(dev: true)
      expect(%w[helpers.rb shout.rb plugin.rb].map { |file| File.symlink?(File.join(plugin_dir, file)) }).to all(be true)
      expect(record.plugin.parts.values).to all(eq(Samagotchi::InstalledBundles::Sha::DEV))
      expect(load_plugin.first).to be true
    end
  end

  describe "load" do
    it "evaluates the parts in their order, then the plugin file, into one fresh module per load" do
      install
      ok, failures = load_plugin
      expect([ok, failures.any?]).to eq([true, false])
      expect(parts_command).to eq("HELLO, PARTS")

      instantiate = lambda do
        Samagotchi::Plugin::Loader.instantiate("plugin-parts", installed.plugin_path, {}, parts: installed.plugin_part_paths)
      end
      first = instantiate.call.class
      second = instantiate.call.class
      expect(second).not_to equal(first)
      expect(second.const_get(:Shout)).not_to equal(first.const_get(:Shout))
      expect(second.const_get(:Shout).superclass).to equal(second.const_get(:Speaker))
    end

    it "fails in the listed order: a part whose class body needs a later part's class" do
      install
      record_path = File.join(bundles_dir, "plugin-parts", "manifest.json")
      data = JSON.parse(File.read(record_path))
      data["plugin"]["parts"] = data["plugin"]["parts"].to_a.reverse.to_h
      File.write(record_path, JSON.generate(data))
      ok, failures = load_plugin
      expect(ok).to be false
      expect(failures.list.first.reason).to match(/NameError: uninitialized constant .*Speaker/)
    end

    it "refuses the whole plugin for an edited part, or a missing one" do
      install
      File.write(File.join(plugin_dir, "shout.rb"), "class Plugin; end\n")
      ok, failures = load_plugin
      expect(ok).to be false
      expect(failures.list.first.reason).to eq("bundle plugin-parts's plugin/shout.rb differs from the installed one (reinstall the bundle)")

      FileUtils.rm(File.join(plugin_dir, "shout.rb"))
      expect(load_plugin.last.list.first.reason).to eq("bundle plugin-parts's plugin/shout.rb is missing (reinstall the bundle)")
      expect(registries.commands.lookup("/parts")).to be_nil
    end

    it "names the part and its line when a part raises as it loads" do
      write_manifest(source, manifest_of(source))
      File.write(File.join(source, "shout.rb"), "class Plugin\n  raise \"part broke\"\nend\n")
      Samagotchi::MemoryBundle::Shas.refresh(source).then { |text, _| File.write(File.join(source, "manifest.yml"), text) }
      install
      failure = load_plugin.last.list.first
      expect(failure.reason).to eq("RuntimeError: part broke")
      expect(failure.location).to eq("#{File.join(plugin_dir, "shout.rb")}:2")
    end

    it "sends a required plugin with a changed part to the guardrail failures" do
      manifest = manifest_of(source)
      manifest["plugin"]["required"] = true
      write_manifest(source, manifest)
      install
      File.write(File.join(plugin_dir, "helpers.rb"), "class Plugin; end\n")
      guardrails = Samagotchi::Guardrails::LoadFailures.new
      plugins = Samagotchi::Guardrails::LoadFailures.new
      ok = Samagotchi::Plugin::Loader.load_bundle("plugin-parts", record, registries, failures: plugins, guardrail_failures: guardrails)
      expect(ok).to be false
      expect(plugins.any?).to be false
      expect(guardrails.list.first).to have_attributes(required: true, reason: %r{plugin/helpers\.rb differs})
    end
  end

  # An older chi installs a too-new plugin with a warning and doesn't read
  # parts:: its record has the plugin file alone, while the kept manifest.yml
  # names the parts.
  describe "a record an older chi wrote (no parts, the kept manifest naming some)" do
    def older_chi_install
      install
      record_path = File.join(bundles_dir, "plugin-parts", "manifest.json")
      data = JSON.parse(File.read(record_path))
      data["plugin"].delete("parts")
      File.write(record_path, JSON.generate(data))
      %w[helpers.rb shout.rb].each { |part| FileUtils.rm(File.join(plugin_dir, part)) }
    end

    it "refuses the plugin as parts_missing, in the loader, status and session settings alike" do
      older_chi_install
      refusal = installed.plugin_refusal(record)
      expect(refusal).to have_attributes(kind: :parts_missing,
                                         text: "bundle plugin-parts's plugin parts aren't installed (reinstall the bundle)")
      expect(load_plugin.last.list.first.reason).to eq(refusal.text)
      status = Samagotchi::MemoryBundle::Status.plugin_status(Samagotchi::MemoryBundle::Provenance.new(name: "plugin-parts"), record)
      expect(status).to include(state: "parts missing", parts: [])
      standing = Samagotchi::InstalledBundles::Standing.of("plugin-parts", record)
      expect(Samagotchi::SessionConfig.send(:unloadable, bundles_dir, standing)).to eq(refusal.text)
    end

    it "is no refusal of that kind without a kept manifest to read" do
      older_chi_install
      FileUtils.rm(File.join(bundles_dir, "plugin-parts", "manifest.yml"))
      expect(installed.plugin_refusal(record)).to be_nil
    end

    it "is cleared by a reinstall" do
      older_chi_install
      install
      expect(installed.plugin_refusal(record)).to be_nil
      expect(load_plugin.first).to be true
    end
  end

  it "hides the bundle's session settings for an edited part, as for an edited plugin file" do
    manifest = manifest_of(source)
    manifest["session_settings"] = ["loud"]
    write_manifest(source, manifest)
    install
    expect(Samagotchi::SessionConfig.availability(dir: bundles_dir).offered).to include("plugin-parts" => ["loud"])
    File.write(File.join(plugin_dir, "shout.rb"), "class Plugin; end\n")
    available = Samagotchi::SessionConfig.availability(dir: bundles_dir)
    expect(available.offered).not_to have_key("plugin-parts")
    expect(available.notes["plugin-parts"]).to include("plugin/shout.rb differs from the installed one")
  end

  it "shows each part's state in the status, the entry's being the plugin file's" do
    install
    File.write(File.join(plugin_dir, "shout.rb"), "class Plugin; end\n")
    status = Samagotchi::MemoryBundle::Status.plugin_status(Samagotchi::MemoryBundle::Provenance.new(name: "plugin-parts"), record)
    expect(status).to include(file: "plugin.rb", state: "ok",
                              parts: [{ file: "helpers.rb", state: "ok" }, { file: "shout.rb", state: "modified" }])
  end

  describe "upgrade and uninstall" do
    def drop_shout(src)
      manifest = manifest_of(src)
      manifest["version"] = "1.1.0"
      manifest["plugin"]["parts"].delete("shout.rb")
      write_manifest(src, manifest)
      File.write(File.join(src, "plugin.rb"), File.read(File.join(src, "plugin.rb")).sub("Shout.new.say(", "("))
      Samagotchi::MemoryBundle::Shas.refresh(src).then { |text, _| File.write(File.join(src, "manifest.yml"), text) }
    end

    it "removes a part the new version drops, saying so, and copies an edited one to the trash first" do
      install
      File.write(File.join(plugin_dir, "shout.rb"), "# mine\n")
      drop_shout(source)
      installer = install(upgrade: true)
      expect(installer.summary).to include("Removed (no longer in the bundle): shout.rb")
      expect(Dir.children(plugin_dir).sort).to eq(%w[helpers.rb plugin.rb])
      expect(record.plugin.parts.keys).to eq(%w[helpers.rb])
      trashed = Dir.glob(File.join(bundles_dir, ".trash", "**", "shout.rb"))
      expect(trashed.map { |path| File.read(path) }).to eq(["# mine\n"])
      expect(load_plugin.first).to be true
      expect(parts_command).to eq("hello, parts")
    end

    it "lists every part the uninstall removes" do
      install
      uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "plugin-parts")
      uninstaller.run
      expect(uninstaller.removed_files).to include("plugin/helpers.rb", "plugin/shout.rb", "plugin/plugin.rb")
    end
  end

  it "builds the installed bundle back with its parts, a bundle that installs and loads" do
    install
    File.write(File.join(Samagotchi::MemoryPaths.system_dir, "work.md"), "# work\n")
    out = File.join(tmpdir, "built")
    Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "plugin-parts", out: out).run
    built = manifest_of(out)
    expect(built["plugin"]["parts"].keys).to eq(%w[helpers.rb shout.rb])
    expect(Samagotchi::MemoryBundle::Shas.stale(out)).to eq([])
    install(out, upgrade: true)
    expect(load_plugin.first).to be true
  end

  it "refuses a build whose recorded part is missing" do
    install
    File.write(File.join(Samagotchi::MemoryPaths.system_dir, "work.md"), "# work\n")
    FileUtils.rm(File.join(plugin_dir, "helpers.rb"))
    expect { Samagotchi::MemoryBundle::Builder.new(scope: "system", name: "plugin-parts", out: File.join(tmpdir, "b")).run }
      .to raise_error(Samagotchi::MemoryBundle::Builder::BuildError, "the installed plugin-parts's plugin part helpers.rb is missing")
  end

  describe "Shas" do
    it "fixes a stale part line, reports one without a sha line, and leaves the layout alone" do
      text = File.read(File.join(source, "manifest.yml"))
      stale = text.sub(/(shout\.rb: sha256:)\h+/, "\\1#{"0" * 64}")
      refreshed, changes = Samagotchi::MemoryBundle::Shas.refresh(source, stale)
      expect(refreshed).to eq(text)
      expect(changes.map(&:first)).to eq(["shout.rb"])

      unlined = text.sub(/    shout\.rb: sha256:\h+\n/, "    shout.rb:\n")
      expect(Samagotchi::MemoryBundle::Shas.stale(source, unlined).map { |s| [s.file, s.old] }).to eq([["shout.rb", nil]])
    end
  end
end
