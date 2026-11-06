# frozen_string_literal: true

require "spec_helper"
require "samagotchi/extension_load"
require "samagotchi/guardrails"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/memory_bundle/installer"
require "tmpdir"
require "json"
require "yaml"

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

  it "hands the hook-failure notice to every installed bundle's hook files" do
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return({})
    record = Samagotchi::MemoryBundle::InstalledBundle.parse("b", hooks: { "k.rb" => { event: "before_turn" } }, trust_level: "reviewed")
    allow(Samagotchi::MemoryBundle::Provenance).to receive(:each_installed).with(holding: :hooks).and_yield("b", record)
    notice = ->(hook, failed, effect: nil) { [hook, failed, effect] }
    expect(Samagotchi::Hooks::BundleLoader).to receive(:load).with(hash_including(hook_failed: notice)).and_return(1)

    described_class.new(hook_failures: Samagotchi::Guardrails::LoadFailures.new, hook_failed: notice).hooks
  end

  it "loads the hooks with no notice when the Engine gives none (the test kit's sandbox)" do
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return({})
    record = Samagotchi::MemoryBundle::InstalledBundle.parse("b", hooks: { "k.rb" => { event: "before_turn" } }, trust_level: "reviewed")
    allow(Samagotchi::MemoryBundle::Provenance).to receive(:each_installed).with(holding: :hooks).and_yield("b", record)
    expect(Samagotchi::Hooks::BundleLoader).to receive(:load).with(hash_including(hook_failed: nil)).and_return(1)

    extension_load.hooks
  end

  it "registers a hook under the events its kept manifest.yml lists when the record lost them, fail-closed as declared" do
    Dir.mktmpdir("ext-kept") do |tmp|
      with_config_home(File.join(tmp, "config")) do
        allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return({})
        src = File.join(tmp, "src")
        FileUtils.mkdir_p(File.join(src, "hooks"))
        File.write(File.join(src, "hooks", "g.rb"), "class G; def call(event); end; end\n")
        File.write(File.join(src, "manifest.yml"), YAML.dump(
          "name" => "g", "version" => "1.0.0", "trust_level" => "reviewed",
          "hooks" => { "g.rb" => { "events" => %w[before_tool_call after_turn], "on_error" => "fail_closed" } }
        ))
        Samagotchi::MemoryBundle::Installer.new(source: src, name: "g", scope: "system").run
        record = File.join(Samagotchi::MemoryPaths.bundles_dir, "g", "manifest.json")
        raw = JSON.parse(File.read(record))
        raw["hooks"]["g.rb"] = raw["hooks"]["g.rb"].except("events").merge("event" => "", "on_error" => "skip")
        File.write(record, JSON.generate(raw))

        # add_bundle_hooks rescues everything a load raises, so the hook is looked at after.
        passed = nil
        allow(Samagotchi::Hooks::BundleLoader).to receive(:load) { |metadata:, **| (passed = metadata) && 1 }
        extension_load.hooks
        hook = passed.fetch("g.rb")
        expect(hook.events).to eq(%w[before_tool_call after_turn])
        expect(hook.fail_closed?("before_tool_call")).to be(true)
        expect(hook.sha256).to eq(raw["hooks"]["g.rb"]["sha256"])
      end
    end
  end

  it "reads config.yml bundles: once" do
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return("b" => { "x" => 1 })
    2.times { expect(extension_load.bundle_settings).to eq("b" => { "x" => 1 }) }
    expect(Samagotchi::ConfigFile).to have_received(:bundle_settings).once
  end

  it "passes the bundle settings to the plugin loader" do
    allow(Samagotchi::ConfigFile).to receive(:bundle_settings).and_return("b" => {})
    allow(Samagotchi::Plugin::Loader).to receive(:load_installed)
    failures = Samagotchi::Guardrails::LoadFailures.new
    extension_load.load_plugins(:registries, failures: failures)

    expect(Samagotchi::Plugin::Loader).to have_received(:load_installed).with(:registries, failures: failures, settings: { "b" => {} })
  end
end
