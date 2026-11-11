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

  # A 0.157 install's record may still list class-file hooks: chi loads none.
  it "loads none of a record's class-file hooks, and adds no failure for them" do
    Dir.mktmpdir("ext-retired") do |tmp|
      with_config_home(File.join(tmp, "config")) do
        failures = Samagotchi::Guardrails::LoadFailures.new
        LegacyHooksRecord.legacy_hooks_record("old", hooks: { "g.rb" => "class G; def call(e) = raise('ran'); end\n" })
        registry = described_class.new(hook_failures: failures).hooks

        expect(registry.bundle_hook_names(:after_turn)).to eq([])
        expect(failures.list).to eq([])
      end
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
