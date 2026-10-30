# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/update_hint"

RSpec.describe Samagotchi::UpdateHint do
  let(:tmp) { Dir.mktmpdir("update-hint") }
  let(:env) { { "XDG_STATE_HOME" => File.join(tmp, "state") } }
  let(:io) { StringIO.new }
  let(:shipped) { Samagotchi::MemoryBundle::SourceNormalizer::SHIPPED_DIR }
  let(:helper) { double("helper", stale?: false) }

  around { |example| with_config_home(File.join(tmp, "config")) { example.run } }

  after { FileUtils.remove_entry(tmp) }

  def install_old(dir)
    dest = File.join(tmp, "old", "lib", "samagotchi", "bundles", dir)
    FileUtils.mkdir_p(File.dirname(dest))
    FileUtils.cp_r(File.join(shipped, dir), dest)
    data = YAML.load_file(File.join(dest, "manifest.yml")).merge("version" => "0.0.1")
    File.write(File.join(dest, "manifest.yml"), YAML.dump(data))
    # The older chi installed it from its own shipped dir.
    Samagotchi::MemoryBundle::Installer.new(source: dest, name: data["name"], scope: "system", shipped_dir: File.dirname(dest)).run
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

  describe ".default_helper" do
    let(:launch) { File.join(tmp, "Library", "Application Support", Samagotchi::Desktop::MacOS::APP_NAME, "launch.json") }
    let(:helper_env) { { "HOME" => tmp, "XDG_CONFIG_HOME" => File.join(tmp, "config") } }

    before { allow(Samagotchi::Desktop).to receive(:supported?).and_return(true) }

    def write_launch(baked)
      FileUtils.mkdir_p(File.dirname(launch))
      File.write(launch, JSON.generate({ "argv" => %w[ruby chi], "env" => baked }))
    end

    it "is the helper whose chi reads this chi's config dir, so an isolated run never hints about another's" do
      write_launch({ "XDG_CONFIG_HOME" => File.join(tmp, "config") })
      expect(described_class.default_helper(helper_env)&.launch_path).to eq(launch)

      write_launch({ "XDG_CONFIG_HOME" => File.join(tmp, "elsewhere") })
      expect(described_class.default_helper(helper_env)).to be_nil
      write_launch({})
      expect(described_class.default_helper(helper_env)).to be_nil
      # No launch file yet: its chi reads ~/.config, the default.
      FileUtils.rm_f(launch)
      with_env("HOME" => tmp) { expect(described_class.default_helper({ "HOME" => tmp })).not_to be_nil }
      expect(described_class.default_helper(helper_env)).to be_nil
    end
  end

  it "is for a person at a terminal running an installed chi" do
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: true, installed: true)).to be(true)
    expect(described_class.wanted?(prompt: "hi", non_interactive: nil, tty: true, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: true, tty: true, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: false, installed: true)).to be(false)
    expect(described_class.wanted?(prompt: nil, non_interactive: nil, tty: true, installed: nil)).to be(false)
  end
end
