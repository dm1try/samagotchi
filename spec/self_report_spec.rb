# frozen_string_literal: true

require "spec_helper"
require "samagotchi/self_report"

RSpec.describe Samagotchi::SelfReport do
  let(:tmp) { Dir.mktmpdir("self-report") }
  let(:config_home) { File.join(tmp, "config") }
  let(:env) { { "XDG_CONFIG_HOME" => config_home, "XDG_STATE_HOME" => File.join(tmp, "state"), "HOME" => tmp } }

  def write_config(yaml)
    FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
    File.write(File.join(config_home, "samagotchi", "config.yml"), yaml)
  end

  def field(name)
    described_class.fields(env: env).to_h.fetch(name)
  end

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(tmp, "bundles")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    FileUtils.remove_entry(tmp)
  end

  it "reports the version and the source dir this code runs from" do
    expect(field("version")).to start_with(Samagotchi::VERSION)
    expect(field("source")).to eq("#{File.expand_path("../", __dir__)} (git checkout)")
  end

  it "resolves config and sessions from the XDG env it is given" do
    write_config("default:\n  model: spec-model\n")
    expect(field("config")).to eq(File.join(config_home, "samagotchi", "config.yml"))
    expect(field("sessions")).to eq(File.join(tmp, "state", "samagotchi", "sessions"))
  end

  it "flags a missing config file" do
    expect(field("config")).to end_with("config.yml (missing)")
  end

  it "reports the hooks dir from config, expanding ~ against HOME" do
    write_config("hooks:\n  hooks_dir: \"~/my_hooks/\"\n")
    expect(field("hooks dir")).to eq(File.join(tmp, "my_hooks/"))
  end

  it "falls back to the default hooks dir" do
    expect(field("hooks dir")).to eq(File.join(tmp, ".config/samagotchi/hooks/"))
  end

  it "reports the configured model with its host" do
    write_config("hosts:\n  main:\n    host: 10.0.0.5\n    port: 8081\n")
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("spec-model")
    expect(field("model")).to eq("spec-model")
    expect(field("host")).to eq("main 10.0.0.5:8081")
  end

  it "says so when no model is configured" do
    allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_raise(ArgumentError)
    expect(field("model")).to eq("(not configured)")
    expect(field("host")).to eq("-")
  end

  it "lists installed bundles and the shipped system bundle version" do
    shipped = Samagotchi::MemoryBundle::Manifest.read(dir: Samagotchi::MemoryBundle::SystemBundle::GEM_BUNDLE_DIR).version
    expect(field("bundles")).to eq("(none installed; shipped system bundle #{shipped})")

    dir = File.join(tmp, "bundles", "samagotchi-system")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate("name" => "samagotchi-system", "version" => "0.0.9"))
    expect(field("bundles")).to eq("samagotchi-system 0.0.9 (shipped #{shipped})")
  end

  describe ".install_kind" do
    it "is 'installed gem' under a gem path" do
      dir = File.join(Gem.path.first, "gems", "samagotchi-9.9.9")
      expect(described_class.install_kind(dir)).to eq("installed gem")
    end

    it "is 'directory' for a plain dir" do
      expect(described_class.install_kind(tmp)).to eq("directory")
    end
  end

  it "renders one aligned line per field" do
    lines = described_class.text(env: env).lines
    expect(lines.size).to eq(described_class.fields(env: env).size)
    expect(lines.first).to match(/\Aversion\s{2,}\S/)
  end
end
