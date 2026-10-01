# frozen_string_literal: true

require "tmpdir"
require "yaml"
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
    let(:aliases) { { "tiny" => "box:gemma-small", "small" => "gemma-small", "chain" => "small" } }

    def parse(raw) = described_class.parse(raw, hosts: hosts, aliases: aliases)

    it "takes a host from the ref" do
      ref = parse("box:gemma-small")
      expect([ref.host_name, ref.id, ref.ref]).to eq(%w[box gemma-small box:gemma-small])
    end

    it "takes the host from the alias's target" do
      ref = parse("tiny")
      expect([ref.host_name, ref.id, ref.alias_name, ref.ref]).to eq(%w[box gemma-small tiny box:gemma-small])
    end

    it "names no host for a bare id or an alias to one" do
      expect([parse("small").host_name, parse("small").ref]).to eq([nil, "gemma-small"])
      expect([parse("other").host_name, parse("other").ref]).to eq([nil, "other"])
    end

    it "applies an alias once" do
      expect(parse("chain").ref).to eq("small")
    end

    it "applies an alias after a host prefix" do
      expect(parse("box:small").ref).to eq("box:gemma-small")
      expect(parse("box:tiny").ref).to eq("box:gemma-small")
      expect(parse("box:tiny").host_conflict).to be_nil
    end

    it "names the alias's host when it differs from the prefix" do
      ref = parse("openrouter:tiny")
      expect([ref.host_name, ref.host_conflict, ref.alias_name]).to eq(%w[openrouter box tiny])
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

    it "#1 /model box:tiny stores box:gemma-small and sends gemma-small to box", step: :F1 do
      e = engine
      expect(e.switch_model!("box:tiny")).to eq("box:gemma-small")
      expect(sent(e)).to eq(%w[box gemma-small])
    end

    it "#1 /model openrouter:tiny is refused: the alias names another host", step: :F1 do
      expect { switched("openrouter:tiny") }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, "alias 'tiny' names host 'box', not 'openrouter'; use tiny or box:tiny")
    end

    it "#2 /model chain resolves one level: small is sent, and routed as small", step: :F1 do
      list_models({ "openai" => ["gemma-small"] })
      expect(sent(switched("chain"))).to eq(%w[openrouter small])
    end

    context "with default.model: small" do
      let(:default_model) { "small" }

      it "#2b a worker sends the alias's target", step: :F1 do
        expect(sent(engine)).to eq(%w[openrouter gemma-small])
      end

      it "#2b a new session stores the target, and the alias as typed", step: :F1 do
        allow(Process).to receive(:spawn).and_return(12_345)
        session = Samagotchi::SessionManager.spawn_session(prompt: nil, state_dir: File.join(tmp, "state"))
        loaded = Samagotchi::Session.load(session.id, state_dir: File.join(tmp, "state"))
        expect([loaded.model_name, loaded.model_typed]).to eq(%w[gemma-small small])
      end
    end

    context "with default.model: tiny" do
      let(:default_model) { "tiny" }

      it "#2b a worker sends the target to box", step: :F1 do
        expect(sent(engine)).to eq(%w[box gemma-small])
      end
    end

    it "#2c chi self names gemma-small as the model box:tiny sends, as the worker does", step: :F1 do
      allow(Samagotchi::ModelProfile).to receive(:required_model_name).and_return("box:tiny")
      host = Samagotchi::SelfReport.fields(env: ENV).to_h.fetch("host")
      expect(host).to eq("box box.test:8081 as gemma-small")
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

    describe "F1: the resolved ref is stored, the typed name kept for models:" do
      let(:config) { super() + "models:\n  small:\n    profile: gemma4\n" }

      def profile_source(engine) = engine.profile_resolution.label

      it "applies models: small after --model small" do
        expect(profile_source(switched("small"))).to eq("config (models: small)")
      end

      it "applies models: small after a resume (the stored ref plus model_typed)" do
        expect(profile_source(engine(model_name: "gemma-small", model_typed: "small"))).to eq("config (models: small)")
        resumed = engine.tap { |e| e.switch_model!("gemma-small", typed: "small") }
        expect(profile_source(resumed)).to eq("config (models: small)")
      end

      it "stores the ref and the alias on the session" do
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "x", working_directory: Dir.pwd)
        switched("tiny").store_model!(session)
        expect([session.model_name, session.model_typed]).to eq(%w[box:gemma-small tiny])
        switched("box:gemma-small").store_model!(session)
        expect([session.model_name, session.model_typed]).to eq(["box:gemma-small", nil])
      end
    end

    context "with default.model: small, an empty session" do
      let(:default_model) { "small" }
      let(:state) { File.join(tmp, "state") }

      it "is still discarded (the stored ref against the alias default)" do
        allow(Process).to receive(:spawn).and_return(12_345)
        session = Samagotchi::SessionManager.spawn_session(prompt: nil, state_dir: state)
        expect(Samagotchi::SessionManager.discardable?(session.id, state_dir: state, default_model: "small")).to be(true)
        expect(Samagotchi::SessionManager.discardable?(session.id, state_dir: state, default_model: "box:other")).to be(false)
      end

      it "keys memory overlays and guardrail rules by the target, reading the alias's old overlay key as a fallback" do
        kernel = Samagotchi::KernelLoop.new(client: nil, profile: :gemma4)
        allow(kernel).to receive(:sync_model_key!).and_call_original
        e = engine(kernel: kernel)
        expect([e.model_key, e.guardrail_model_name]).to eq(%w[gemma-small gemma-small])
        expect(kernel).to have_received(:sync_model_key!).with("gemma-small", fallback: "small")
      end
    end

    it "refuses a session on a host:alias naming another host (a web 400)" do
      allow(Process).to receive(:spawn).and_return(12_345)
      expect { Samagotchi::SessionManager.spawn_session(prompt: nil, model_name: "openrouter:tiny", state_dir: File.join(tmp, "state")) }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, /alias 'tiny' names host 'box'/)
      expect(Process).not_to have_received(:spawn)
    end

    it "warns at start that aliases don't chain" do
      problems = Samagotchi::Config.validate_yaml_sections(YAML.safe_load(config))
      expect(problems).to eq(["config: model_aliases.chain points to the alias 'small'; aliases don't chain, so 'small' is sent as written"])
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
