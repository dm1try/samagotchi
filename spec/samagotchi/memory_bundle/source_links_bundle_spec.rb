# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/hooks/registry"
require "samagotchi/hooks/bundle_loader"

# The shipped source-links bundle, end to end: install it into an isolated
# bundles dir, load its hook, fire a synthetic :after_turn and see the
# sources line, then uninstall cleanly.
RSpec.describe "Source-links bundle E2E" do
  let(:tmpdir) { Dir.mktmpdir("source-links-e2e-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:bundles_dir) { File.join(system_dir, ".bundles") }
  let(:fixture_path) { File.expand_path("../../../lib/samagotchi/bundles/source-links", __dir__) }

  before do
    FileUtils.mkdir_p(system_dir)
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "installs, loads the hook, announces the refs, and uninstalls cleanly" do
    installer = Samagotchi::MemoryBundle::Installer.new(source: fixture_path, name: "source-links", scope: "system",
                                                        force: false, strict: true)
    installer.run
    expect(File.exist?(File.join(bundles_dir, "source-links", "hooks", "source_links.rb"))).to be true
    expect(File.exist?(File.join(system_dir, "source_links.md"))).to be true

    prov = Samagotchi::MemoryBundle::Provenance.new(name: "source-links")
    data = prov.read
    expect(data[:hooks]).to include(:"source_links.rb")
    expect(data[:trust_level]).to eq("reviewed")

    settings = { "sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }] }
    registry = Samagotchi::Hooks::Registry.new
    loaded = Samagotchi::Hooks::BundleLoader.load(bundle_name: "source-links", hooks_dir: prov.hooks_dir,
                                                  metadata: data[:hooks], registry: registry, settings: settings)
    expect(loaded).to eq(1)

    notices = []
    registry.runtime = Samagotchi::Hooks::Runtime.new(
      notify: ->(**kw) { notices << kw },
      ask_user: ->(**) { nil },
      stop_turn: ->(**) { false }
    )
    registry.fire(:after_turn, { type: :after_turn, status: "completed",
                                 messages: [{ role: "model", content: "Fixed in JIRA-123." }] })
    expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])

    uninstaller = Samagotchi::MemoryBundle::Uninstaller.new(name: "source-links", force: false)
    uninstaller.run
    expect(Dir.exist?(File.join(bundles_dir, "source-links"))).to be false
    expect(uninstaller.removed_files).to include("hooks/source_links.rb")
  end
end
