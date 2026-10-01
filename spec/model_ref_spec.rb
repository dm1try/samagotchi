# frozen_string_literal: true

require "tmpdir"
require "samagotchi/model_ref"
require "samagotchi/engine"
require "samagotchi/session_commands"
require "samagotchi/session_manager"
require "samagotchi/self_report"
require "samagotchi/turn_flow"

RSpec.describe Samagotchi::ModelRef do
  describe ".split" do
    let(:hosts) { { "box" => {}, "openai" => {} } }

    it "splits off a configured host's prefix, downcased" do
      expect(described_class.split(" Box:gemma-small ", hosts: hosts)).to eq(%w[box gemma-small])
    end

    it "keeps a ref whose prefix is no configured host, or with nothing after it" do
      expect(described_class.split("qwen3:8b", hosts: hosts)).to eq([nil, "qwen3:8b"])
      expect(described_class.split("box:", hosts: hosts)).to eq([nil, "box:"])
      expect(described_class.split("", hosts: hosts)).to eq([nil, ""])
    end
  end

  describe ".parse" do
    let(:hosts) { { "box" => {}, "openrouter" => {} } }
    let(:aliases) { { "tiny" => "box:gemma-small", "small" => "gemma-small" } }

    def parse(raw) = described_class.parse(raw, hosts: hosts, aliases: aliases)

    it "takes a host from the ref" do
      ref = parse("box:gemma-small")
      expect([ref.host_name, ref.alias_resolved, ref.sent_id_unresolved]).to eq(%w[box gemma-small gemma-small])
    end

    it "takes the host from the alias's target" do
      ref = parse("tiny")
      expect([ref.host_name, ref.alias_resolved, ref.alias_ref]).to eq(%w[box gemma-small box:gemma-small])
    end

    it "names no host for a bare id or an alias to one" do
      expect(parse("small").host_name).to be_nil
      expect(parse("small").alias_resolved).to eq("gemma-small")
      expect(parse("other").alias_resolved).to eq("other")
    end
  end

  # How each entry point resolves model refs, row by row from the plan's
  # table (tmp/plans/20261001-model-ref-resolution.md). A row tagged with a
  # step changes in that step.
  describe "characterization" do
    let(:tmp) { Dir.mktmpdir("model-ref") }
    let(:config) do
      <<~YAML
        default:
          model: #{default_model}
        hosts:
          openrouter:
            url: https://openrouter.test/api/v1
            api: openai
            api_key_env: SPEC_OPENROUTER_KEY
          openai:
            url: https://openai.test/v1
            api: openai
            api_key_env: SPEC_OPENAI_KEY
          box:
            host: box.test
            port: 8081
          qwen3:
            host: qwen.test
            port: 8082
        model_aliases:
          tiny: box:gemma-small
          small: gemma-small
          chain: small
      YAML
    end
    let(:default_model) { "spec-model" }
    let(:registry) { Samagotchi::HostRegistry.new }

    around do |example|
      with_config_home(tmp) do
        File.write(File.join(tmp, "samagotchi", "config.yml"), config)
        with_env("SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_HOSTS_JSON" => nil) do
          Samagotchi::Config.reload!(cli_overrides: {})
          example.run
        ensure
          Samagotchi::Config.reload!(cli_overrides: {})
        end
      end
    ensure
      FileUtils.remove_entry(tmp)
    end

    before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

    def info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

    # The hosts' model lists, as /models gets them (+slow+ answers last).
    def list_models(lists, slow: nil)
      allow(registry).to receive(:list_models_for) do |entry|
        sleep 0.2 if entry.name == slow
        Array(lists[entry.name]).map { |id| info(id) }
      end
      registry.list_all_models
    end

    def engine(**options)
      Samagotchi::Engine.new(host_registry: registry, **options)
    end

    # [host, model id] the engine's turn goes to.
    def sent(engine)
      [registry.resolve(engine.effective_model_name).entry.name, engine.bare_model_name(engine.effective_model_name)]
    end

    def switched(name)
      engine.tap { |e| e.switch_model!(name) }
    end

    it "#1 /model box:tiny stores box:box:gemma-small and sends box:gemma-small", step: :F1 do
      e = engine
      expect(e.switch_model!("box:tiny")).to eq("box:box:gemma-small")
      expect(sent(e)).to eq(["box", "box:gemma-small"])
    end

    it "#1 /model openrouter:tiny sends box:gemma-small to openrouter", step: :F1 do
      expect(sent(switched("openrouter:tiny"))).to eq(["openrouter", "box:gemma-small"])
    end

    it "#2 /model chain routes on gemma-small but sends small", step: :F1 do
      list_models({ "openai" => ["gemma-small"] })
      expect(sent(switched("chain"))).to eq(%w[openai small])
    end

    context "with default.model: small" do
      let(:default_model) { "small" }

      it "#2b a worker sends the alias literally", step: :F1 do
        expect(sent(engine)).to eq(%w[openrouter small])
      end

      it "#2b a new session stores the alias", step: :F1 do
        allow(Process).to receive(:spawn).and_return(12_345)
        session = Samagotchi::SessionManager.spawn_session(prompt: nil, state_dir: File.join(tmp, "state"))
        expect(Samagotchi::Session.load(session.id, state_dir: File.join(tmp, "state")).model_name).to eq("small")
      end
    end

    context "with default.model: tiny" do
      let(:default_model) { "tiny" }

      it "#2b a worker routes to box but sends tiny", step: :F1 do
        expect(sent(engine)).to eq(%w[box tiny])
      end
    end

    it "#2c chi self names box:gemma-small as the model box:tiny sends", step: :F1 do
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("box:tiny")
      host = Samagotchi::SelfReport.fields(env: ENV).to_h.fetch("host")
      expect(host).to eq("box box.test:8081 as box:gemma-small")
    end

    it "#3 openai/gpt-4o goes to the openai host as gpt-4o", step: :F2 do
      expect(sent(switched("openai/gpt-4o"))).to eq(%w[openai gpt-4o])
    end

    it "#3 recap on openrouter with openai/gpt-4o sends gpt-4o", :recap, step: :F2 do
      e = engine(model_name: "box:m", recap: { host_ref: "openrouter", model: "openai/gpt-4o" })
      expect(e.recap.target).to include(base_url: "https://openrouter.test/api/v1", model: "gpt-4o")
    end

    it "#4 qwen3:8b goes to the qwen3 host as 8b" do
      expect(sent(switched("qwen3:8b"))).to eq(%w[qwen3 8b])
    end

    it "#5 a bare id listed on two hosts goes to the host that answered /models first", step: :F3 do
      list_models({ "box" => ["gemma-small"], "qwen3" => ["gemma-small"] }, slow: "box")
      expect(sent(switched("gemma-small"))).to eq(%w[qwen3 gemma-small])
    end

    it "#5 a bare id before /models goes to the default host" do
      expect(sent(switched("gemma-small"))).to eq(%w[openrouter gemma-small])
    end

    it "#6 /model gemma after /models goes to a local host listing gemma-small", step: :F3 do
      list_models({ "box" => ["gemma-small"] })
      expect(sent(switched("gemma"))).to eq(%w[box gemma])
    end

    it "#7 recap.model: small sends small", :recap, step: :F4 do
      e = engine(model_name: "box:m", recap: { host_ref: "box", model: "small" })
      expect(e.recap.target).to include(base_url: "http://box.test:8081/v1", model: "small")
    end

    it "#7 recap with host_ref: openrouter and model: box:x drops box", :recap, step: :F4 do
      e = engine(model_name: "box:m", recap: { host_ref: "openrouter", model: "box:x" })
      expect(e.recap.target).to include(base_url: "https://openrouter.test/api/v1", model: "x")
    end

    it "#7 recap.model: box:x without host_ref turns recap off", :recap, step: :F4 do
      expect(engine(model_name: "box:m", recap: { model: "box:x" }).recap).to be_nil
    end

    it "#9 /models shows an alias for box:gemma-small under every host listing gemma-small", step: :F2 do
      list_models({ "box" => ["gemma-small"], "qwen3" => ["gemma-small"] })
      e = engine(model_name: "box:m")
      commands = Samagotchi::SessionCommands.new(engine: e, turn_flow: Samagotchi::TurnFlow.new(engine: e), default_model: "box:m")
      allow(registry).to receive(:list_all_models).and_return(registry.cached_results)
      lines = commands.run("/models").output.lines(chomp: true)
      expect(lines).to include("box (box.test:8081):", "qwen3 (qwen.test:8082):")
      expect(lines.grep(/gemma-small/)).to eq(["  gemma-small (alias: small, tiny)", "  gemma-small (alias: small, tiny)"])
    end
  end
end
