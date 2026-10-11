# frozen_string_literal: true

require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"
require "samagotchi/model_settings"
require "samagotchi/steer_cut_after"

# The seconds a message sent as a cut waits for a thinking-only generation
# (steer.cut_after per host and model): parsing, and where it is configured
# and in which order.
RSpec.describe Samagotchi::SteerCutAfter do
  def with_config(text)
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "samagotchi")
      FileUtils.mkdir_p(config_dir)
      path = File.join(config_dir, "config.yml")
      File.write(path, text)
      yield path, dir
    end
  end

  def target_for(path, model)
    hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
    Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).resolve(model)
  end

  before { Samagotchi::ConfigFile.reset_warnings! }
  after { Samagotchi::Config.reload!(cli_overrides: {}) }

  describe ".seconds" do
    it "takes whole seconds, 0 included, as a number or a string" do
      expect(described_class.seconds(0, "x")).to eq(0)
      expect(described_class.seconds(15, "x")).to eq(15)
      expect(described_class.seconds("15", "x")).to eq(15)
      expect(described_class.seconds(nil, "x")).to be_nil
    end

    it "warns once about anything else and counts it as unset" do
      expect { expect(described_class.seconds(-1, "models: q")).to be_nil }
        .to output(/models: q: steer_cut_after must be whole seconds \(0 = never\); ignored/).to_stderr
      expect { described_class.seconds("abc", "models: q") }.not_to output.to_stderr
      expect { described_class.seconds(1.5, "models: q") }.not_to output.to_stderr
    end
  end

  describe ".resolve" do
    let(:yaml) do
      <<~YAML
        steer:
          cut_after: 30
        hosts:
          splash:
            host: h
            steer_cut_after: 0
          work:
            host: w
            steer_cut_after: 45
          plain:
            host: p
        models:
          qwen:
            steer_cut_after: 90
      YAML
    end

    def resolve(path, dir, model, env: {})
      with_env({ "XDG_CONFIG_HOME" => dir, "SAMAGOTCHI_STEER_CUT_AFTER" => nil }.merge(env)) do
        Samagotchi::Config.reload!(cli_overrides: {})
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        target = target_for(path, model)
        described_class.resolve(target, names: [target.model, target.bare_model], models: models)
      end
    end

    it "takes the env over the model, the host and the file" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "splash:qwen", env: { "SAMAGOTCHI_STEER_CUT_AFTER" => "5" }))
          .to eq([5, "SAMAGOTCHI_STEER_CUT_AFTER"])
      end
    end

    it "takes the model entry, then the host entry, then steer.cut_after (0 = never, not skipped)" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "splash:qwen")).to eq([90, "models: qwen"])
        expect(resolve(path, dir, "splash:other")).to eq([0, "hosts.splash"])
        expect(resolve(path, dir, "work:other")).to eq([45, "hosts.work"])
        expect(resolve(path, dir, "plain:other")).to eq([30, "steer.cut_after"])
      end
    end

    it "is the default with nothing set" do
      with_config("hosts:\n  plain:\n    host: p\n") do |path, dir|
        expect(resolve(path, dir, "plain:other")).to eq([20, nil])
      end
    end
  end

  describe ".label" do
    it "names the seconds and the source, and never for 0 or less" do
      expect(described_class.label(60, "models: qwen")).to eq("after 60 s (models: qwen)")
      expect(described_class.label(0, "hosts.splash")).to eq("never (hosts.splash)")
    end
  end
end
