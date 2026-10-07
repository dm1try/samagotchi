# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require "samagotchi/config"
require "samagotchi/host_registry"
require "samagotchi/llm_context_strategy"

RSpec.describe Samagotchi::LLMContextStrategy do
  def with_config(data)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, data.to_yaml)
      yield path
    end
  end

  def target(layers = nil)
    entry = Samagotchi::HostRegistry::HostEntry.new(name: "box", host: "box", port: 8080, llm_context_strategy: layers)
    Samagotchi::HostRegistry::ModelTarget.new(model: "box:m", entry: entry, bare_model: "m", client: nil)
  end

  before { Samagotchi::ConfigFile.reset_warnings! }

  describe ".parse" do
    it "reads none, a name, \"|\"-separated names and a YAML list; nil is unset" do
      expect(described_class.parse(nil, "x")).to be_nil
      expect(described_class.parse("none", "x")).to eq([])
      expect(described_class.parse(" ", "x")).to eq([])
      expect(described_class.parse([], "x")).to eq([])
      expect(described_class.parse("Stale", "x")).to eq([:stale])
      expect(described_class.parse("stale | forget", "x")).to eq(%i[stale forget])
      expect(described_class.parse(%w[stale forget stale], "x")).to eq(%i[stale forget])
    end

    it "warns once about an unknown name, and is none" do
      expect { expect(described_class.parse(%w[stale summarize], "models: m")).to eq([]) }
        .to output(/models: m: unknown llm_context strategy summarize .*using none/).to_stderr
      expect { described_class.parse(%w[stale summarize], "models: m") }.not_to output.to_stderr
      expect { expect(described_class.parse(%w[none stale], "x")).to eq([]) }.to output(/unknown llm_context strategy none/).to_stderr
    end
  end

  describe ".resolve" do
    before { allow(Samagotchi::Config).to receive(:get).and_call_original }

    def config(value)
      allow(Samagotchi::Config).to receive(:get).with(described_class::SETTING).and_return(value)
    end

    it "is none by default, from llm_context.strategy" do
      config("none")

      expect(described_class.resolve(target, names: %w[m], models: {}).to_h)
        .to eq(layers: [], strategy: :none, source: :config)
    end

    it "takes the model's setting, then the host's, then llm_context.strategy (a model's none wins too)" do
      config("stale")
      models = { "m" => { llm_context_strategy: [] } }

      expect(described_class.resolve(target([:stale]), names: %w[box:m m], models: models).source).to eq(:model_setting)
      expect(described_class.resolve(target([]), names: %w[m], models: {}).source).to eq(:host_setting)
      expect(described_class.resolve(target, names: %w[m], models: {}).to_h)
        .to eq(layers: [:stale], strategy: [:stale], source: :config)
    end

    it "takes the session's own layers first, once something sets them" do
      models = { "m" => { llm_context_strategy: [] } }

      expect(described_class.resolve(target, names: %w[m], models: models, session: []).source).to eq(:session)
    end

    it "runs stale, and warns that a layer isn't built yet and runs the turn under none (forget, P4)" do
      models = { "m" => { llm_context_strategy: [:stale] }, "d" => { llm_context_strategy: %i[stale forget] } }
      resolved = nil

      expect { resolved = described_class.resolve(target, names: %w[m], models: models) }.not_to output.to_stderr
      expect(resolved.to_h).to eq(layers: [:stale], strategy: [:stale], source: :model_setting)
      expect { resolved = described_class.resolve(target, names: %w[d], models: models) }
        .to output(/models: d: llm_context strategy forget is not built yet; using none/).to_stderr
      expect(resolved.to_h).to eq(layers: %i[stale forget], strategy: :none, source: :model_setting)
    end
  end

  describe "the config file" do
    it "reads llm_context_strategy on models: and hosts: entries, a string or a YAML list" do
      with_config("models" => { "Qwen3.6-35B" => { "llm_context_strategy" => "stale" },
                                "deepseek" => { "llm_context_strategy" => %w[stale forget] },
                                "other" => { "profile" => "qwen36" } },
                  "hosts" => { "box" => { "host" => "h", "llm_context_strategy" => "none" },
                               "plain" => { "host" => "p" } }) do |path|
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

        expect(models["qwen3.6-35b"][:llm_context_strategy]).to eq([:stale])
        expect(models["deepseek"][:llm_context_strategy]).to eq(%i[stale forget])
        expect(models["other"]).not_to have_key(:llm_context_strategy)
        expect(hosts["box"][:llm_context_strategy]).to eq([])
        expect(hosts["plain"][:llm_context_strategy]).to be_nil
        expect(Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).entries["box"].llm_context_strategy).to eq([])
      end
    end

    it "knows llm_context.strategy and the flat keys (no unknown-key warning), a YAML list joined" do
      data = { "llm_context" => { "strategy" => %w[stale forget] },
               "models" => { "m" => { "llm_context_strategy" => "stale" } },
               "hosts" => { "box" => { "host" => "h", "llm_context_strategy" => ["stale"] } } }

      expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
      expect(Samagotchi::Config.resolve(described_class::SETTING, file_data: data, env: {})).to eq("stale|forget")
      expect(Samagotchi::Config.resolve(described_class::SETTING, file_data: {}, env: {})).to eq("none")
    end
  end
end
