# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/hooks/registry"
require "samagotchi/hooks/bundle_loader"
require "samagotchi/guardrails"
require "samagotchi/tools/memory"
require "yaml"
require "digest"

RSpec.describe "Sample hooks bundle E2E", type: :integration do
  let(:tmpdir) { Dir.mktmpdir("sample-e2e-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:fixture_path) { File.expand_path("../../../spec/fixtures/sample_hooks_bundle", __dir__) } # spec/fixtures/sample_hooks_bundle

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

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
    bad = Samagotchi::Guardrails::Verdict.new(call: { name: "bad_tool" })
    registry.fire(:before_tool_call, { tool_name: "bad_tool", guardrail: bad })
    expect(bad).to be_deny

    # good tool passes
    good = Samagotchi::Guardrails::Verdict.new(call: { name: "good_tool" })
    registry.fire(:before_tool_call, { tool_name: "good_tool", guardrail: good })
    expect(good).to be_allow

    # uninstall cleanly
    uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "sample-hooks-bundle", force: false)
    uninstaller.run
    expect(Dir.exist?(File.join(bundles_dir, "sample-hooks-bundle"))).to be false
    expect(uninstaller.removed_files).to include("hooks/guardrails.rb")
  end

  it "installs a model overlay that only its model reads, with no index line, and uninstalls both" do
    key = "deepseek-v4-1-flash"
    src = File.join(tmpdir, "ovl-src")
    FileUtils.mkdir_p(src)
    files = { "tips.md" => "Base tips.\n", "tips.#{key}.md" => "DeepSeek: keep answers short.\n" }
    files.each { |f, body| File.write(File.join(src, f), body) }
    File.write(File.join(src, "manifest.yml"), YAML.dump(
      "name" => "ovl-test", "version" => "0.1.0",
      "files" => files.to_h { |f, body| [f, "sha256:#{Digest::SHA256.hexdigest(body)}"] }
    ))

    installer = Samagotchi::MemoryBundle::Installer.new(source: src, name: "ovl-test", scope: "system", strict: true)
    installer.run
    expect(installer.warnings).to be_empty

    index = File.read(File.join(system_dir, "index.md"))
    expect(index.scan(/^- \*\*([^*]+)\*\*/).flatten).to eq(["tips"])

    read = Samagotchi::Tools::MemoryRead
    expect(read.call("tips", scope: "system", model_key: key)).to include("Base tips.", "DeepSeek: keep answers short.")
    expect(read.call("tips", scope: "system", model_key: "qwen3-6-35b-a3b")).to eq("Base tips.\n")

    Samagotchi::MemoryBundle::Uninstaller.new(name: "ovl-test").run
    expect(File.exist?(File.join(system_dir, "tips.md"))).to be false
    expect(File.exist?(File.join(system_dir, "tips.#{key}.md"))).to be false
    expect(File.read(File.join(system_dir, "index.md"))).not_to include("tips")
  end
end
