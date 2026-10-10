# frozen_string_literal: true

require "spec_helper"
require "open3"
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

  def target(layers = nil, apply: nil, budget: nil)
    entry = Samagotchi::HostRegistry::HostEntry.new(name: "box", host: "box", port: 8080, llm_context_strategy: layers,
                                                    llm_context_apply: apply, llm_context_budget_tokens: budget)
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
        .to eq(layers: [], strategy: :none, source: :config, apply: :payoff, protect_steps: 3, stale_edits: false,
               budget_tokens: nil)
    end

    it "takes the model's setting, then the host's, then llm_context.strategy (a model's none wins too)" do
      config("stale")
      models = { "m" => { llm_context_strategy: [] } }

      expect(described_class.resolve(target([:stale]), names: %w[box:m m], models: models).source).to eq(:model_setting)
      expect(described_class.resolve(target([]), names: %w[m], models: {}).source).to eq(:host_setting)
      expect(described_class.resolve(target, names: %w[m], models: {}).to_h)
        .to include(layers: [:stale], strategy: [:stale], source: :config)
    end

    it "takes the session's own layers first, once something sets them" do
      models = { "m" => { llm_context_strategy: [] } }

      expect(described_class.resolve(target, names: %w[m], models: models, session: []).source).to eq(:session)
    end

    it "runs stale, and stale with forget, and names the layers a turn runs under" do
      models = { "m" => { llm_context_strategy: [:stale] }, "d" => { llm_context_strategy: %i[stale forget] } }
      resolved = nil

      expect { resolved = described_class.resolve(target, names: %w[m], models: models) }.not_to output.to_stderr
      expect(resolved.to_h).to include(layers: [:stale], strategy: [:stale], source: :model_setting)
      expect { resolved = described_class.resolve(target, names: %w[d], models: models) }.not_to output.to_stderr
      expect(resolved.to_h).to include(layers: %i[stale forget], strategy: %i[stale forget], source: :model_setting)
      expect(resolved.active_layers).to eq(%i[stale forget])
      expect(described_class.resolve(target, names: %w[x], models: models).active_layers).to eq([])
    end

    it "takes the apply rule from the session, the model, the host, then llm_context.apply, apart from the layers" do
      allow(Samagotchi::Config).to receive(:get).with(described_class::APPLY_SETTING).and_return("turn_end")
      models = { "m" => { llm_context_apply: :next_request }, "s" => { llm_context_strategy: [:stale] } }

      expect(described_class.resolve(target(apply: :payoff), names: %w[m], models: models).apply).to eq(:next_request)
      expect(described_class.resolve(target(apply: :payoff), names: %w[s], models: models).apply).to eq(:payoff)
      expect(described_class.resolve(target, names: %w[s], models: models).apply).to eq(:turn_end)
      expect(described_class.resolve(target, names: %w[m], models: models, session_apply: :payoff).apply).to eq(:payoff)
    end

    it "turns edit-driven stale stubs on only with llm_context.stale_edits: true (off by default, opt-in)" do
      allow(Samagotchi::Config).to receive(:get).with(described_class::STALE_EDITS_SETTING).and_return(nil, true)

      expect(described_class.resolve(target, names: %w[m], models: {}).stale_edits).to be(false)
      expect(described_class.resolve(target, names: %w[m], models: {}).stale_edits).to be(true)
    end

    it "reads llm_context.protect_steps, a negative one as the default" do
      allow(Samagotchi::Config).to receive(:get).with(described_class::PROTECT_SETTING).and_return(0, -1)

      expect(described_class.resolve(target, names: %w[m], models: {}).protect_steps).to eq(0)
      expect(described_class.resolve(target, names: %w[m], models: {}).protect_steps).to eq(3)
    end
  end

  describe ".explain" do
    before { allow(Samagotchi::Config).to receive(:get).and_call_original }

    it "names where the strategy, the apply rule and the budget each came from" do
      models = { "m" => { llm_context_strategy: [:stale], llm_context_budget_tokens: 48_000 } }

      explained = described_class.explain(target(apply: :turn_end), names: %w[m], models: models)

      expect(explained.resolved).to eq(described_class.resolve(target(apply: :turn_end), names: %w[m], models: models))
      expect(explained.strategy.to_h).to eq(source: :model_setting, where: "models: m")
      expect(explained.apply.to_h).to eq(source: :host_setting, where: "hosts entry 'box'")
      expect(explained.budget_tokens.to_h).to eq(source: :model_setting, where: "models: m")
      expect(described_class.explain(target, names: %w[x], models: {}).apply.to_h)
        .to eq(source: :config, where: "llm_context.apply")
    end

    it "takes the session's own values first: none and a budget of 0 (off) too" do
      models = { "m" => { llm_context_strategy: [:stale], llm_context_apply: :turn_end, llm_context_budget_tokens: 48_000 } }

      explained = described_class.explain(target, names: %w[m], models: models, session: [], session_apply: :next_request,
                                                  session_budget: 0)

      expect(explained.resolved.to_h).to include(strategy: :none, source: :session, apply: :next_request, budget_tokens: nil)
      expect([explained.strategy, explained.apply, explained.budget_tokens].map(&:source)).to all(eq(:session))
    end
  end

  describe ".parse_apply" do
    it "reads the three rules, any case; blank is unset; an unknown one warns once and is payoff" do
      expect(described_class.parse_apply(nil, "x")).to be_nil
      expect(described_class.parse_apply(" ", "x")).to be_nil
      expect(described_class.parse_apply("Turn_End", "x")).to eq(:turn_end)
      expect(described_class.parse_apply(:next_request, "x")).to eq(:next_request)
      expect { expect(described_class.parse_apply("later", "models: m")).to eq(:payoff) }
        .to output(/models: m: unknown llm_context apply later .*using payoff/).to_stderr
    end
  end

  describe "the budget" do
    it "is off by default, and comes from the session, the model, the host, then llm_context.budget_tokens" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      models = { "m" => { llm_context_budget_tokens: 48_000 } }

      expect(described_class.resolve(target, names: %w[x], models: models).budget_tokens).to be_nil
      expect(described_class.resolve(target(budget: 96_000), names: %w[m], models: models).budget_tokens).to eq(48_000)
      expect(described_class.resolve(target(budget: 96_000), names: %w[x], models: models).budget_tokens).to eq(96_000)
      allow(Samagotchi::Config).to receive(:get).with(described_class::BUDGET_SETTING).and_return(64_000)
      expect(described_class.resolve(target, names: %w[x], models: models).budget_tokens).to eq(64_000)
      expect(described_class.resolve(target, names: %w[m], models: models, session_budget: 1000).budget_tokens).to eq(1000)
    end

    it "reads tokens or k as /llm-context budget does (4k to 10M); off and 0 are unset; anything else warns" do
      expect(described_class.parse_budget(nil, "x")).to be_nil
      expect(described_class.parse_budget("64000", "x")).to eq(64_000)
      expect(described_class.parse_budget(64_000, "x")).to eq(64_000)
      expect(described_class.parse_budget("64k", "x")).to eq(64_000)
      expect(described_class.parse_budget("48_000", "x")).to eq(48_000)
      expect { expect(described_class.parse_budget(0, "x")).to be_nil }.not_to output.to_stderr
      expect { expect(described_class.parse_budget("off", "x")).to be_nil }.not_to output.to_stderr
      expect { expect(described_class.parse_budget("-5", "models: m")).to be_nil }
        .to output(/models: m: a budget is a number of tokens \(64000 or 64k\) or off; ignored/).to_stderr
      expect { expect(described_class.parse_budget(1000, "hosts entry 'b'")).to be_nil }
        .to output(/hosts entry 'b': a budget of 1000 tokens is out of range: 4000 \(4k\) to 10000000 \(10000k\), or off; ignored/)
        .to_stderr
    end

    it "takes 64k and off in llm_context.budget_tokens, models: and hosts: (config.yml and the environment)" do
      data = { "llm_context" => { "budget_tokens" => "64k" },
               "models" => { "deepseek" => { "llm_context_budget_tokens" => "48k" } },
               "hosts" => { "box" => { "host" => "h", "llm_context_budget_tokens" => "off" } } }
      with_config(data) do |path|
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

        expect(models["deepseek"][:llm_context_budget_tokens]).to eq(48_000)
        expect(hosts["box"].llm_context_budget_tokens).to be_nil
      end
      expect { Samagotchi::Config.resolve(described_class::BUDGET_SETTING, file_data: data, env: {}) }.not_to output.to_stderr
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with(described_class::BUDGET_SETTING)
        .and_return(Samagotchi::Config.resolve(described_class::BUDGET_SETTING, file_data: data, env: {}))
      expect(described_class.resolve(target, names: %w[x], models: {}).budget_tokens).to eq(64_000)
      expect(Samagotchi::Config.resolve(described_class::BUDGET_SETTING, file_data: {},
                                        env: { "SAMAGOTCHI_LLM_CONTEXT_BUDGET_TOKENS" => "32k" })).to eq("32k")
    end

    it "is read on models: and hosts: entries, and llm_context.budget_tokens is a known setting" do
      data = { "llm_context" => { "budget_tokens" => 64_000 },
               "models" => { "deepseek" => { "llm_context_budget_tokens" => 48_000 } },
               "hosts" => { "box" => { "host" => "h", "llm_context_budget_tokens" => 32_000 } } }
      with_config(data) do |path|
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

        expect(models["deepseek"][:llm_context_budget_tokens]).to eq(48_000)
        expect(Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).entries["box"].llm_context_budget_tokens).to eq(32_000)
      end
      expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
      expect(described_class.parse_budget(Samagotchi::Config.resolve(described_class::BUDGET_SETTING, file_data: data, env: {}),
                                          "x")).to eq(64_000)
      expect(Samagotchi::Config.resolve(described_class::BUDGET_SETTING, file_data: {}, env: {})).to be_nil
    end
  end

  describe "the config file" do
    it "reads llm_context_apply on models: and hosts: entries" do
      with_config("models" => { "deepseek" => { "llm_context_apply" => "next_request" }, "other" => { "profile" => "x" } },
                  "hosts" => { "box" => { "host" => "h", "llm_context_apply" => "turn_end" } }) do |path|
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)

        expect(models["deepseek"][:llm_context_apply]).to eq(:next_request)
        expect(models["other"]).not_to have_key(:llm_context_apply)
        expect(Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).entries["box"].llm_context_apply).to eq(:turn_end)
      end
    end

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
        expect(hosts["box"].llm_context_strategy).to eq([])
        expect(hosts["plain"].llm_context_strategy).to be_nil
        expect(Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).entries["box"].llm_context_strategy).to eq([])
      end
    end

    it "knows llm_context.strategy and the flat keys (no unknown-key warning), a YAML list joined" do
      data = { "llm_context" => { "strategy" => %w[stale forget], "apply" => "turn_end", "protect_steps" => 2 },
               "models" => { "m" => { "llm_context_strategy" => "stale", "llm_context_apply" => "payoff" } },
               "hosts" => { "box" => { "host" => "h", "llm_context_strategy" => ["stale"], "llm_context_apply" => "payoff" } } }

      expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
      expect(Samagotchi::Config.resolve(described_class::SETTING, file_data: data, env: {})).to eq("stale|forget")
      expect(Samagotchi::Config.resolve(described_class::SETTING, file_data: {}, env: {})).to eq("none")
      expect(Samagotchi::Config.resolve(described_class::APPLY_SETTING, file_data: data, env: {})).to eq("turn_end")
      expect(Samagotchi::Config.resolve(described_class::APPLY_SETTING, file_data: {}, env: {})).to eq("payoff")
      expect(Samagotchi::Config.resolve(described_class::PROTECT_SETTING, file_data: data, env: {})).to eq(2)
      expect(Samagotchi::Config.resolve(described_class::PROTECT_SETTING, file_data: {}, env: {})).to eq(3)
      expect(Samagotchi::Config.resolve(described_class::STALE_EDITS_SETTING, file_data: {}, env: {})).to be(false)
      expect(Samagotchi::Config.resolve(described_class::STALE_EDITS_SETTING,
                                        file_data: { "llm_context" => { "stale_edits" => true } }, env: {})).to be(true)
    end
  end

  describe ".for_session" do
    # Loaded on its own (a session list's ctx %, before anything loaded
    # ModelProfile): a session with no model takes the configured default.
    it "resolves a session without a model to the default model when loaded alone" do
      script = <<~RUBY
        require "samagotchi/session"
        require "samagotchi/llm_context_strategy"
        registry = Object.new
        def registry.resolve(name) = (puts "resolve \#{name}"; nil)
        def registry.lookup_names(*, **) = []
        session = Samagotchi::Session.new_session(mode: "assist", model_name: nil, working_directory: "/w")
        p Samagotchi::LLMContextStrategy.for_session(session, registry: registry)&.fetch(:strategy)
      RUBY
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script, stdin_data: "")

      expect(status).to be_success, err
      expect(out.lines.map(&:chomp)).to eq(["resolve spec-model", '"none"'])
    end
  end
end
