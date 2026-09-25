# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/config"
require "samagotchi/memory_bundle/provenance"

# config.yml `bundles:` reaches a bundle's hooks as their settings.
RSpec.describe Samagotchi::Engine, "bundle settings" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }

  def stub_config(data)
    allow(Samagotchi::ConfigFile).to receive(:read_yaml).and_call_original
    allow(Samagotchi::ConfigFile).to receive(:read_yaml).with(path: Samagotchi::ConfigFile.global_path).and_return(data)
  end

  def installed(bundle_name)
    allow(Samagotchi::MemoryBundle::Provenance).to receive(:each_installed_holding_hooks)
      .and_yield(bundle_name, { hooks: { "k.rb" => { event: "before_tool_call" } }, trust_level: "reviewed" })
  end

  it "passes the bundle's section to BundleLoader.load, {} for a bundle without one" do
    stub_config({ "bundles" => { "known-names" => { "names" => ["x"], "mode" => "ask" } } })
    installed("known-names")
    expect(Samagotchi::Hooks::BundleLoader).to receive(:load)
      .with(hash_including(bundle_name: "known-names", settings: { "names" => ["x"], "mode" => "ask" })).and_return(1)
    described_class.new(mode: :assist, client: client)

    installed("other")
    expect(Samagotchi::Hooks::BundleLoader).to receive(:load).with(hash_including(bundle_name: "other", settings: {})).and_return(1)
    described_class.new(mode: :assist, client: client)
  end

  it "ignores a bundles: section that is not a mapping, with one warning" do
    stub_config({ "bundles" => ["known-names"] })
    installed("known-names")
    expect(Samagotchi::Log).to receive(:warn).with(:hooks, "bundles_section_invalid", anything).once
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    expect(Samagotchi::Hooks::BundleLoader).to receive(:load).with(hash_including(settings: {})).and_return(1)
    described_class.new(mode: :assist, client: client)
  end

  it "is an accepted top-level config section" do
    expect(Samagotchi::Config.validate_yaml_sections("bundles" => { "known-names" => { "mode" => "reject" } })).to eq([])
  end
end
