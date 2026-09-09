# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "digest"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/builder"

RSpec.describe Samagotchi::MemoryBundle::Builder do
  let(:tmpdir) { Dir.mktmpdir("builder-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }

  before do
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = bundles_dir
    FileUtils.mkdir_p(system_dir)
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  def write_bundle_with_hooks(files = {}, hooks = {}, name: "test-bundle", version: "1.0.0", trust_level: "reviewed")
    src = File.join(tmpdir, "src_#{name}_#{rand(1000)}")
    FileUtils.mkdir_p(src)
    FileUtils.mkdir_p(File.join(src, "hooks"))
    files.each { |k, v| File.write(File.join(src, k), v) }
    hooks.each { |k, v| File.write(File.join(src, "hooks", k), v) }
    manifest = { "name" => name, "version" => version, "files" => {}, "hooks" => {} }
    files.each { |k, v| manifest["files"][k] = "sha256:#{Digest::SHA256.hexdigest(v)}" }
    hooks.each { |k, v| manifest["hooks"][k] = { "sha256" => "sha256:#{Digest::SHA256.hexdigest(v)}", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => 10 } }
    manifest["trust_level"] = trust_level if trust_level
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  it "builds hooks/*.rb and hooks: manifest round-trip" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, { "guardrails.rb" => "class Guardrails; def call(e); end; end" }, name: "build-hook", trust_level: "reviewed")
    inst = Samagotchi::MemoryBundle::Installer.new(source: src, name: "build-hook", scope: "system", force: false, strict: true)
    inst.run
    out = File.join(tmpdir, "out")
    builder = described_class.new(scope: "system", name: "build-hook", version: "1.0.0", out: out)
    result = builder.run
    expect(File.exist?(File.join(out, "hooks", "guardrails.rb"))).to be true
    manifest = YAML.load_file(File.join(out, "manifest.yml"))
    expect(manifest["hooks"]).to include("guardrails.rb")
    expect(manifest["trust_level"]).to eq("reviewed")
    expect(result[:files]).to include("identity.md")
  end

  it "build without hooks still succeeds" do
    src = write_bundle_with_hooks({ "identity.md" => "# Id\n" }, {}, name: "no-hook-build")
    inst = Samagotchi::MemoryBundle::Installer.new(source: src, name: "no-hook-build", scope: "system", force: false, strict: true)
    inst.run
    out = File.join(tmpdir, "out2")
    builder = described_class.new(scope: "system", name: "no-hook-build", version: "1.0.0", out: out)
    expect { builder.run }.not_to raise_error
    manifest = YAML.load_file(File.join(out, "manifest.yml"))
    expect(manifest["hooks"]).to be_nil
  end
end
