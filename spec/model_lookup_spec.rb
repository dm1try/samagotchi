# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "yaml"
require "samagotchi/host_registry"
require "samagotchi/model_lookup"

RSpec.describe Samagotchi::ModelLookup do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "box" => { host: "127.0.0.1", port: 1, thinking: :low, window_tokens: 9000 } })
  end
  let(:target) { registry.resolve("box:qwen") }
  let(:models) do
    { "small" => Samagotchi::ModelSettings.new(thinking: :off),
      "qwen" => Samagotchi::ModelSettings.new(thinking: :high, sampling: { temperature: 0.5 }) }
  end

  describe "#model" do
    it "walks the names most specific first and names the key that set the field" do
      lookup = described_class.for(target, names: %w[small box:qwen qwen], models: models)

      expect(lookup.model(:thinking)).to eq(Samagotchi::ModelSetting.new(key: "small", value: :off))
      expect(lookup.model(:sampling)).to eq(Samagotchi::ModelSetting.new(key: "qwen", value: { temperature: 0.5 }))
      expect(lookup.model(:vision)).to be_nil
    end

    it "reads config.yml's models: at each call without a given map, and {} when that can't be read" do
      allow(Samagotchi::ModelSettings).to receive(:all).and_return(models)
      lookup = described_class.for(target, names: %w[qwen])
      expect(lookup.model(:thinking)&.value).to eq(:high)

      allow(Samagotchi::ModelSettings).to receive(:all).and_raise(IOError, "config gone")
      expect(lookup.models).to eq({})
      expect(lookup.model(:thinking)).to be_nil
    end
  end

  describe "#host" do
    it "is the host entry's field, nil without a target" do
      lookup = described_class.for(target, names: [])

      expect([lookup.host(:thinking), lookup.host(:window_tokens), lookup.host(:vision), lookup.host_name])
        .to eq([:low, 9000, nil, "box"])
      expect(described_class.for(nil, names: []).host(:thinking)).to be_nil
    end
  end

  describe "#global" do
    let(:dir) { Dir.mktmpdir("model-lookup") }

    after { FileUtils.rm_rf(dir) }

    def write_config(data)
      FileUtils.mkdir_p(File.join(dir, "samagotchi"))
      File.write(File.join(dir, "samagotchi", "config.yml"), YAML.dump(data))
    end

    it "is Config.get_with_origin for the process ENV, CLI settings included" do
      lookup = described_class.for(target, names: [])
      with_env("SAMAGOTCHI_THINKING_LEVEL" => "low") do
        expect(lookup.global("thinking.level")).to eq(Samagotchi::Config.get_with_origin("thinking.level"))
        expect(lookup.global("thinking.level")).to eq(["low", :env])
      end
      Samagotchi::Config.reload!(cli_overrides: { "thinking.level" => "high" })
      expect(lookup.global("thinking.level")).to eq(["high", :cli])
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end

    it "reads another env's variables and config file" do
      write_config("steer" => { "cut_after" => 33 })
      env = { "XDG_CONFIG_HOME" => dir }

      expect(described_class.for(target, names: [], env: env).global("steer.cut_after")).to eq([33, :file])
      expect(described_class.for(target, names: [], env: env.merge("SAMAGOTCHI_STEER_CUT_AFTER" => "4"))
                            .global("steer.cut_after")).to eq([4, :env])
    end
  end

  it "prints no env and no client" do
    lookup = described_class.for(target, names: %w[qwen], env: { "KEY" => "sk-secret" })

    expect(lookup.inspect).to eq('#<Samagotchi::ModelLookup "box:qwen" host="box" names=["qwen"]>')
  end

  # The class map's rule (no cycle back through the setting modules): its
  # code names ModelSettings, ModelSetting, Config and ConfigFile, nothing
  # else of chi's.
  it "names no constant of chi's but ModelSettings, ModelSetting, Config and ConfigFile in its code" do
    source = File.read(File.expand_path("../lib/samagotchi/model_lookup.rb", __dir__))
    code = source.lines.reject { |line| line.strip.start_with?("#") }.join.gsub(/"[^"]*"/, "")
    named = code.scan(/\b[A-Z][A-Za-z0-9]*/).uniq - %w[ENV StandardError Data Array Samagotchi ModelLookup]

    expect(named).to all(satisfy { |name| %w[ModelSettings ModelSetting Config ConfigFile].include?(name) })
    expect(named).to include("ModelSettings", "Config")
  end
end
