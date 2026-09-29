# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "yaml"
require "samagotchi/update_hint"

RSpec.describe Samagotchi::UpdateHint do
  let(:tmp) { Dir.mktmpdir("update-hint") }
  let(:env) { { "XDG_STATE_HOME" => File.join(tmp, "state") } }
  let(:io) { StringIO.new }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }
  let(:helper) { double("helper", stale?: false) }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(tmp, "memories", ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = File.join(tmp, "memories")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.remove_entry(tmp)
  end

  def install_old(dir)
    dest = File.join(tmp, "old", "lib", "samagotchi", "bundles", dir)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, dir), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml")).merge("version" => "0.0.1")
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data))
    Samagotchi::MemoryBundle::Installer.new(source: dest, name: data["name"], scope: "system").run
  end

  def show(version: "9.0.0") = described_class.show(io: io, env: env, version: version, helper: helper, shipped_dir: shipped)

  it "says what is behind once per version" do
    install_old("btw")
    install_old("known-names")
    allow(helper).to receive(:stale?).and_return(true)

    expect(show).to eq("chi 9.0.0: 2 bundles and the desktop helper can be updated: chi update")
    expect(io.string).to eq("chi 9.0.0: 2 bundles and the desktop helper can be updated: chi update\n")
    expect(show).to be_nil
    expect(show(version: "9.0.1")).to start_with("chi 9.0.1: 2 bundles")
  end

  it "says nothing when nothing is behind, and still notes the version" do
    expect(show).to be_nil
    expect(io.string).to eq("")
    install_old("btw")
    expect(show).to be_nil
    expect(show(version: "9.0.1")).to eq("chi 9.0.1: 1 bundle can be updated: chi update")
  end

  it "says the helper alone, and nothing off macOS" do
    allow(helper).to receive(:stale?).and_return(true)
    expect(show).to eq("chi 9.0.0: the desktop helper can be updated: chi update")
    expect(described_class.show(io: io, env: env, version: "9.0.1", helper: nil, shipped_dir: shipped)).to be_nil
  end

  it "is for a person at a terminal running an installed chi" do
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: true, installed: true)).to be(true)
    expect(described_class.wanted?(prompt: "hi", non_interactive: nil, tty: true, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: true, tty: true, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: false, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: true, installed: nil)).to be(false)
  end
end
