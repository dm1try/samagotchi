# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/config"

# config.yml `bundles:`: the bundles' settings (a plugin's: spec/samagotchi/plugin/).
RSpec.describe Samagotchi::Engine, "bundle settings" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { instance_double(Samagotchi::Client) }

  def stub_config(data)
    allow(Samagotchi::ConfigFile).to receive(:read_yaml).and_call_original
    allow(Samagotchi::ConfigFile).to receive(:read_yaml).with(path: Samagotchi::ConfigFile.global_path).and_return(data)
  end

  it "ignores a bundles: section that is not a mapping, with one warning" do
    stub_config({ "bundles" => ["known-names"] })
    expect(Samagotchi::Log).to receive(:warn).with(:hooks, "bundles_section_invalid", anything).once
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    described_class.new(client: client)
  end

  it "is an accepted top-level config section" do
    expect(Samagotchi::Config.validate_yaml_sections("bundles" => { "known-names" => { "mode" => "reject" } })).to eq([])
  end
end
