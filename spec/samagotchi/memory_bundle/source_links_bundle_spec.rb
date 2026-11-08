# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/hooks/registry"
require "samagotchi/plugin/loader"

# The shipped source-links bundle, end to end: install it into an isolated
# bundles dir, load its plugin as chi does, fire a synthetic :after_turn and see the
# sources line, then uninstall cleanly.
RSpec.describe "Source-links bundle E2E" do
  let(:tmpdir) { Dir.mktmpdir("source-links-e2e-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:fixture_path) { File.expand_path("../../../lib/samagotchi/bundles/source-links", __dir__) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  before do
    FileUtils.mkdir_p(system_dir)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "installs, loads the plugin's hook, announces the refs, and uninstalls cleanly" do
    installer = Samagotchi::MemoryBundle::Installer.new(source: fixture_path, name: "source-links", scope: "system",
                                                        force: false, strict: true)
    installer.run
    expect(File.exist?(File.join(bundles_dir, "source-links", "plugin", "plugin.rb"))).to be true
    expect(Dir.exist?(File.join(bundles_dir, "source-links", "hooks"))).to be false
    expect(File.exist?(File.join(system_dir, "source_links.md"))).to be true

    prov = Samagotchi::MemoryBundle::Provenance.new(name: "source-links")
    data = prov.read
    expect(data[:hooks].to_h).to eq({})
    expect(data[:plugin]).to include(file: "plugin.rb")
    expect(data[:trust_level]).to eq("reviewed")

    settings = { "sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }] }
    registry = Samagotchi::Hooks::Registry.new
    failures = Samagotchi::Guardrails::LoadFailures.new
    loaded = Samagotchi::Plugin::Loader.load_bundle("source-links", prov.record, Samagotchi::Plugin::Registries.new(hooks: registry),
                                                    failures: failures, settings: settings)
    expect([loaded, failures.list]).to eq([true, []])
    expect(registry.bundle_hook_names(:after_turn)).to eq([["source-links", "plugin.rb", 90]])

    notices = []
    registry.runtime = Samagotchi::Hooks::Runtime.new(
      notify: ->(**kw) { notices << kw },
      ask_user: ->(_question) {},
      stop_turn: ->(**) { false }
    )
    registry.fire(:after_turn, { type: :after_turn, status: "completed",
                                 messages: [{ role: "model", content: "Fixed in JIRA-123." }] })
    expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])

    uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "source-links", force: false)
    uninstaller.run
    expect(Dir.exist?(File.join(bundles_dir, "source-links"))).to be false
    expect(uninstaller.removed_files).to include("plugin/plugin.rb")
  end
end
