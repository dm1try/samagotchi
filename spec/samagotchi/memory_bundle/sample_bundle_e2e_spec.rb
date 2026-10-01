# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/hooks/registry"
require "samagotchi/hooks/bundle_loader"

RSpec.describe "Sample hooks bundle E2E", type: :integration do
  let(:tmpdir) { Dir.mktmpdir("sample-e2e-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:fixture_path) { File.expand_path("../../../spec/fixtures/sample_hooks_bundle", __dir__) } # spec/fixtures/sample_hooks_bundle

  before do
    FileUtils.mkdir_p(system_dir)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "installs, loads guardrail, vetoes tool call, and uninstalls cleanly (definition of done)" do
    skip "fixture not found" unless File.exist?(File.join(fixture_path, "manifest.yml"))

    installer = Samagotchi::MemoryBundle::Installer.new(source: fixture_path, name: "sample-hooks-bundle", scope: "system", force: false, strict: true)
    installer.run
    expect(File.exist?(File.join(bundles_dir, "sample-hooks-bundle", "hooks", "guardrails.rb"))).to be true
    expect(File.exist?(File.join(system_dir, "identity.md"))).to be true

    prov = Samagotchi::MemoryBundle::Provenance.new(name: "sample-hooks-bundle")
    data = prov.read
    expect(data[:hooks]).to include(:"guardrails.rb")
    expect(data[:trust_level]).to eq("reviewed")

    registry = Samagotchi::Hooks::Registry.new
    loaded = Samagotchi::Hooks::BundleLoader.load(bundle_name: "sample-hooks-bundle", hooks_dir: prov.hooks_dir, metadata: data[:hooks], registry: registry)
    expect(loaded).to eq(1)

    # vetoes bad_tool
    e = { tool_name: "bad_tool", blocked: false }
    registry.fire(:before_tool_call, e)
    expect(e[:blocked]).to be true

    # good tool passes
    e2 = { tool_name: "good_tool", blocked: false }
    registry.fire(:before_tool_call, e2)
    expect(e2[:blocked]).not_to be true

    # uninstall cleanly
    uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "sample-hooks-bundle", force: false)
    uninstaller.run
    expect(Dir.exist?(File.join(bundles_dir, "sample-hooks-bundle"))).to be false
    expect(uninstaller.removed_files).to include("hooks/guardrails.rb")
  end
end
