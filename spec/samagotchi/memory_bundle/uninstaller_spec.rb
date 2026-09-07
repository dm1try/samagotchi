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

RSpec.describe Samagotchi::MemoryBundle::Uninstaller do
  let(:tmpdir) { Dir.mktmpdir("uninstaller-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }

  before do
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = bundles_dir
    described_class.system_dir_override = system_dir
    described_class.project_dir_base_override = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(system_dir)
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    described_class.system_dir_override = nil
    described_class.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
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

  it "memory-only bundles unaffected" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "no-hook")
    install_bundle(src, "no-hook")
    uninstaller = described_class.new(name: "no-hook", force: false)
    expect { uninstaller.run }.not_to raise_error
    expect(uninstaller.removed_files).to include("identity.md")
  end

  it "removes provenance bundle_dir even when hooks present" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, { "a.rb" => "class A; def call(e); end; end", "b.rb" => "class B; def call(e); end; end" }, name: "multi-hook")
    install_bundle(src, "multi-hook")
    described_class.new(name: "multi-hook", force: false).run
    expect(Dir.exist?(File.join(bundles_dir, "multi-hook"))).to be false
  end
end
