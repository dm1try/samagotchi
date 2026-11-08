# frozen_string_literal: true

require "spec_helper"
require "samagotchi/extension_load"
require "samagotchi/guardrails"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/installer"
require "tmpdir"
require "json"
require "yaml"
require_relative "support/legacy_hooks_record"

RSpec.describe Samagotchi::ExtensionLoad do
  subject(:extension_load) { described_class.new(hook_failures: Samagotchi::Guardrails::LoadFailures.new) }

  it "holds nothing and isn't loading before the plugins load" do
    expect(extension_load.held_events).to eq([])
    expect(extension_load.loading?).to be false
  end

  it "is loading only while the plugins load, and holds what they show then" do
    seen = nil
    allow(Samagotchi::Plugin::Loader).to receive(:load_installed) do
      seen = extension_load.loading?
      extension_load.hold({ type: :hook_notice, text: "loaded" })
    end
    extension_load.load_plugins(Object.new, failures: nil)

    expect(seen).to be true
    expect(extension_load.loading?).to be false
    expect(extension_load.held_events).to eq([{ type: :hook_notice, text: "loaded" }])
  end

  it "stops loading when a plugin load raises" do
    allow(Samagotchi::Plugin::Loader).to receive(:load_installed).and_raise("boom")

    expect { extension_load.load_plugins(Object.new, failures: nil) }.to raise_error("boom")
    expect(extension_load.loading?).to be false
  end

  describe "a record that still has class-file hooks (a 0.157 install)" do
    around do |example|
      Dir.mktmpdir("ext-retired") { |tmp| with_config_home(File.join(tmp, "config")) { example.run } }
    end

    let(:failures) { Samagotchi::Guardrails::LoadFailures.new }

    it "loads none of them and adds one not-required failure per record, in the retired words" do
      LegacyHooksRecord.legacy_hooks_record("old", hooks: { "g.rb" => "class G; def call(e) = raise('ran'); end\n",
                                                            "h.rb" => "class H; end\n" })
      registry = described_class.new(hook_failures: failures).hooks

      expect(registry.bundle_hook_names(:after_turn)).to eq([])
      expect(failures.list.map { |f| [f.what, f.reason, f.required] })
        .to eq([["hooks (bundle old)", Samagotchi::MemoryBundle::Manifest::HooksRetired::WORDS, false]])
      expect(failures.required).to eq([])
    end

    it "says nothing of an empty hooks map or an empty hooks/ dir" do
      LegacyHooksRecord.legacy_hooks_record("empty", hooks: {})
      FileUtils.mkdir_p(File.join(Samagotchi::MemoryPaths.bundles_dir, "empty", "hooks"))
      described_class.new(hook_failures: failures).hooks

      expect(failures.list).to eq([])
    end

    it "is silent for a hooks-only record whose manifest.json doesn't read (the plugin loader and the rules report theirs)" do
      dir = File.join(Samagotchi::MemoryPaths.bundles_dir, "broken")
      FileUtils.mkdir_p(File.join(dir, "hooks"))
      File.write(File.join(dir, "manifest.json"), "{ not json")
      described_class.new(hook_failures: failures).hooks

      expect(failures.list).to eq([])
    end
  end

  it "reads config.yml bundles: once" do
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return("b" => { "x" => 1 })
    2.times { expect(extension_load.bundle_settings).to eq("b" => { "x" => 1 }) }
    expect(Samagotchi::ConfigFile).to have_received(:bundle_settings).once
  end

  it "passes the bundle settings to the plugin loader, and the hook failures for a required plugin's" do
    hook_failures = Samagotchi::Guardrails::LoadFailures.new
    extension_load = described_class.new(hook_failures: hook_failures)
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return("b" => {})
    allow(Samagotchi::Plugin::Loader).to receive(:load_installed)
    failures = Samagotchi::Guardrails::LoadFailures.new
    extension_load.load_plugins(:registries, failures: failures)

    expect(Samagotchi::Plugin::Loader).to have_received(:load_installed)
      .with(:registries, failures: failures, guardrail_failures: hook_failures, settings: { "b" => {} })
  end
end
