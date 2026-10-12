# frozen_string_literal: true

require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"
require "samagotchi/reasoning_history"

# reasoning_history (drop|turn|all): which of its own reasoning a chat
# host's model gets back, where it is configured and in which order.
RSpec.describe Samagotchi::ReasoningHistory do
  def with_config(text)
    Dir.mktmpdir do |dir|
      config_dir = File.join(dir, "samagotchi")
      FileUtils.mkdir_p(config_dir)
      path = File.join(config_dir, "config.yml")
      File.write(path, text)
      yield path, dir
    end
  end

  def resolve(path, dir, model, env: {}, session: nil, how: :resolve)
    with_env({ "XDG_CONFIG_HOME" => dir, "SAMAGOTCHI_REASONING_HISTORY" => nil }.merge(env)) do
      models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
      hosts = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
      target = Samagotchi::HostRegistry.new(hosts_config: hosts, env: {}).resolve(model)
      described_class.public_send(how, target, names: [target.model, target.bare_model], models: models, session: session)
    end
  end

  before { Samagotchi::ConfigFile.reset_warnings! }

  describe ".run_start" do
    let(:run) do
      [{ role: "user", content: "go" }, { role: "model", content: "call one", thinking: "plan first" },
       { role: "tool_response", content: "one" }]
    end

    it "is nil without a run start" do
      expect(described_class.run_start(run, nil)).to be_nil
    end

    it "is the run's start" do
      expect(described_class.run_start(run, 1)).to eq(1)
    end

    it "stays at the run's start past a steer the run merged" do
      merged = run + [{ role: "user", content: "finish and commit" }, { role: "model", content: "call two" },
                      { role: "tool_response", content: "two" }]

      expect(described_class.run_start(merged, 1)).to eq(1)
    end

    it "starts past a user entry added after the run's last reply (a !cmd's output)" do
      expect(described_class.run_start(run + [{ role: "user", content: "!ls output" }], 1)).to eq(4)
    end

    it "starts past a turn_start entry added after the run's last reply" do
      expect(described_class.run_start(run + [{ role: "system", content: "wake", turn_start: true }], 1)).to eq(4)
    end

    it "is a fresh run's start when it begins at the conversation's end" do
      expect(described_class.run_start(run + [{ role: "user", content: "next" }], 4)).to eq(4)
    end
  end

  describe ".level" do
    it "takes the three levels, any case" do
      expect(%w[drop turn All].map { |v| described_class.level(v, "x") }).to eq(%i[drop turn all])
    end

    it "is nil when unset" do
      expect(described_class.level(nil, "x")).to be_nil
    end

    it "warns once about anything else and counts it as unset" do
      expect { expect(described_class.level("off", "models: q")).to be_nil }
        .to output(/models: q: reasoning_history must be one of drop, turn, all; ignored/).to_stderr
      expect { described_class.level("off", "models: q") }.not_to output.to_stderr
    end
  end

  describe ".resolve" do
    let(:yaml) do
      <<~YAML
        hosts:
          work:
            host: h
            api: openai
            reasoning_history: all
          other:
            host: o
            api: openai
        models:
          qwen:
            reasoning_history: drop
      YAML
    end

    it "takes the environment first, then the models: entry, then the host, then turn" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "work:qwen", env: { "SAMAGOTCHI_REASONING_HISTORY" => "all" }))
          .to eq([:all, "SAMAGOTCHI_REASONING_HISTORY"])
        expect(resolve(path, dir, "work:qwen")).to eq([:drop, "models: qwen"])
        expect(resolve(path, dir, "work:gemma")).to eq([:all, "hosts.work"])
        expect(resolve(path, dir, "other:gemma")).to eq([:turn, nil])
      end
    end

    it "takes the session's own level before all of them" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "work:qwen", env: { "SAMAGOTCHI_REASONING_HISTORY" => "all" }, session: :turn))
          .to eq([:turn, "session"])
        expect(resolve(path, dir, "other:gemma", session: :drop)).to eq([:drop, "session"])
      end
    end

    it "warns about an unknown environment value and goes on as if unset" do
      with_config(yaml) do |path, dir|
        expect { expect(resolve(path, dir, "other:m", env: { "SAMAGOTCHI_REASONING_HISTORY" => "yes" })).to eq([:turn, nil]) }
          .to output(/SAMAGOTCHI_REASONING_HISTORY: reasoning_history must be one of/).to_stderr
      end
    end

    it "reads the host and model keys without an unknown-key warning" do
      problems = Samagotchi::Config.validate_yaml_sections(YAML.safe_load(yaml))
      expect(problems).to eq([])
    end
  end

  describe ".explain" do
    it "is the resolved level with its source and the session's own beside it" do
      with_config("hosts:\n  work:\n    host: h\n    api: openai\n    reasoning_history: drop\n") do |path, dir|
        expect(resolve(path, dir, "work:m", how: :explain))
          .to eq(Samagotchi::SettingExplained.new(level: :drop, source: "hosts.work", own: nil))
        explained = resolve(path, dir, "work:m", session: :all, how: :explain)
        expect(explained.summary).to eq(level: "all", source: "session", own: "all")
        expect(explained.label).to eq("all (session)")
      end
    end
  end

  describe ".session_level" do
    it "takes the three levels from a word or symbol, an explicit turn included" do
      expect([:drop, "Turn", " all "].map { |v| described_class.session_level(v) }).to eq(%i[drop turn all])
    end

    it "is nil, without a warning, for default and anything else" do
      expect { expect(["default", "off", nil, :low, 3].map { |v| described_class.session_level(v) }).to all(be_nil) }
        .not_to output.to_stderr
    end
  end

  describe ".cache_cost" do
    def target(chat: true) = Struct.new(:entry).new(Struct.new(:chat?).new(chat))

    let(:thought) do
      [{ role: "user", content: "hi" }, { role: "model", content: "ok", thinking: "let me see" }, { role: "user", content: "and?" }]
    end
    let(:unthought) { [{ role: "user", content: "hi" }, { role: "model", content: "ok", thinking: " \n" }] }

    it "is :history to or from all on a chat host once an earlier reply has thinking, local or remote" do
      %i[drop turn].each do |other|
        expect(described_class.cache_cost(other, :all, target: target, conversation: thought)).to eq(:history)
        expect(described_class.cache_cost(:all, other, target: target, conversation: thought)).to eq(:history)
      end
    end

    it "is nothing between drop and turn, for no change, with nothing thought yet, or on a native host" do
      expect(described_class.cache_cost(:drop, :turn, target: target, conversation: thought)).to be_nil
      expect(described_class.cache_cost(:turn, :drop, target: target, conversation: thought)).to be_nil
      expect(described_class.cache_cost(:all, :all, target: target, conversation: thought)).to be_nil
      expect(described_class.cache_cost(:turn, :all, target: target, conversation: unthought)).to be_nil
      expect(described_class.cache_cost(:turn, :all, target: target, conversation: [])).to be_nil
      expect(described_class.cache_cost(:turn, :all, target: target(chat: false), conversation: thought)).to be_nil
    end
  end

  describe ".label" do
    it "names the source, or says default" do
      expect(described_class.label(:drop, "models: qwen")).to eq("drop (models: qwen)")
      expect(described_class.label(:turn, nil)).to eq("turn (default)")
    end
  end
end
