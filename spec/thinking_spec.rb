# frozen_string_literal: true

require "tmpdir"
require "samagotchi/config"
require "samagotchi/host_registry"
require "samagotchi/model_profile"
require "samagotchi/thinking"

# The thinking: level (off|low|medium|high|default): parsing, where it is
# configured and in which order, and what each backend gets for it.
RSpec.describe Samagotchi::Thinking do
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

  describe ".level" do
    it "takes the five levels, any case" do
      expect(%w[off low medium high default].map { |v| described_class.level(v, "x") })
        .to eq(%i[off low medium high default])
      expect(described_class.level("Medium", "x")).to eq(:medium)
    end

    it "reads YAML's unquoted off (false) as off" do
      expect(described_class.level(false, "x")).to eq(:off)
      expect(described_class.level("false", "x")).to eq(:off)
    end

    it "is nil when unset" do
      expect(described_class.level(nil, "x")).to be_nil
    end

    it "warns once about anything else and counts it as unset" do
      expect { expect(described_class.level("med", "models: q")).to be_nil }
        .to output(/models: q: thinking must be one of off, low, medium, high, default; ignored/).to_stderr
      expect { described_class.level("med", "models: q") }.not_to output.to_stderr
    end

    it "says `on` isn't a level (YAML's unquoted on is true)" do
      expect { expect(described_class.level(true, "hosts entry 'w'")).to be_nil }
        .to output(/`on` isn't one, `default` leaves it to the model/).to_stderr
    end
  end

  describe "config" do
    it "reads unquoted off in hosts:, models: and thinking.level" do
      with_config(<<~YAML) do |path, dir|
        thinking:
          level: off
        hosts:
          work:
            host: h
            thinking: off
        models:
          qwen:
            thinking: off
      YAML
        expect(Samagotchi::ConfigFile.hosts_config(env: {}, path: path)["work"].thinking).to eq(:off)
        expect(Samagotchi::ConfigFile.model_settings(env: {}, path: path)["qwen"].thinking).to eq(:off)
        with_env("XDG_CONFIG_HOME" => dir, "SAMAGOTCHI_THINKING_LEVEL" => nil) do
          expect(described_class.global_level).to eq(%i[off file])
        end
      end
    end

    it "keeps config.yml's thinking.level out of the env (there it would outrank the models: and hosts: entries)" do
      with_config("thinking:\n  level: high\n") do |path|
        env = {}
        Samagotchi::ConfigFile.load!(env: env, path: path)

        expect(env).not_to have_key("SAMAGOTCHI_THINKING_LEVEL")
      end
    end

    it "knows thinking as a host and model key (no unknown-key warning)" do
      data = { "thinking" => { "level" => "low" }, "hosts" => { "w" => { "host" => "h", "thinking" => "low" } },
               "models" => { "q" => { "thinking" => "high" } } }
      expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
    end

    it "carries a host's level to workers in SAMAGOTCHI_HOSTS_JSON" do
      with_config("hosts:\n  work:\n    host: h\n    thinking: off\n") do |path|
        json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json }, path: File.join(Dir.tmpdir, "none.yml"))
        expect(hosts["work"].thinking).to eq(:off)
      end
    end
  end

  describe ".resolve" do
    let(:yaml) do
      <<~YAML
        thinking:
          level: high
        hosts:
          work:
            host: h
            thinking: low
          other:
            host: o
        models:
          qwen:
            thinking: off
      YAML
    end

    def resolve(path, dir, model, env: {}, cli: {}, session: nil, how: :resolve)
      with_env({ "XDG_CONFIG_HOME" => dir, "SAMAGOTCHI_THINKING_LEVEL" => nil }.merge(env)) do
        Samagotchi::Config.reload!(cli_overrides: cli)
        models = Samagotchi::ConfigFile.model_settings(env: {}, path: path)
        target = target_for(path, model)
        described_class.public_send(how, target, names: [target.model, target.bare_model], models: models, session: session)
      end
    end

    it "takes the session's own level first, over --thinking, the env and the model entry" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "work:qwen", session: :low)).to eq([:low, "session"])
        expect(resolve(path, dir, "work:qwen", session: :high, cli: { "thinking.level" => "off" })).to eq([:high, "session"])
        expect(resolve(path, dir, "work:qwen", session: :medium, env: { "SAMAGOTCHI_THINKING_LEVEL" => "off" }))
          .to eq([:medium, "session"])
        expect(resolve(path, dir, "work:qwen", env: { "SAMAGOTCHI_THINKING_LEVEL" => "low" }))
          .to eq([:low, "SAMAGOTCHI_THINKING_LEVEL"])
      end
    end

    it "explains the level with its source and the session's own beside it" do
      with_config(yaml) do |path, dir|
        own = resolve(path, dir, "work:qwen", session: :low, how: :explain)
        expect(own.summary).to eq(level: "low", source: "session", own: "low")
        expect(own.label).to eq("low (session)")

        model = resolve(path, dir, "work:qwen", how: :explain)
        expect(model.summary).to eq(level: "off", source: "models: qwen", own: nil)
        expect(model.label).to eq("off (models: qwen)")
      end
      with_config("hosts:\n  other:\n    host: o\n") do |path, dir|
        expect(resolve(path, dir, "other:m", how: :explain).label).to eq("default")
      end
    end

    it "takes the model entry, then the host entry, then thinking.level" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "work:qwen")).to eq([:off, "models: qwen"])
        expect(resolve(path, dir, "work:other-model")).to eq([:low, "hosts.work"])
        expect(resolve(path, dir, "other:other-model")).to eq([:high, "thinking.level"])
      end
    end

    it "lets --thinking and the env outrank the model and host entries" do
      with_config(yaml) do |path, dir|
        expect(resolve(path, dir, "work:qwen", cli: { "thinking.level" => "medium" })).to eq([:medium, "--thinking"])
        expect(resolve(path, dir, "work:qwen", env: { "SAMAGOTCHI_THINKING_LEVEL" => "default" }))
          .to eq([:default, "SAMAGOTCHI_THINKING_LEVEL"])
      end
    end

    it "is default with nothing set" do
      with_config("hosts:\n  other:\n    host: o\n") do |path, dir|
        expect(resolve(path, dir, "other:m")).to eq([:default, nil])
      end
    end

    it "skips a bad env value (warned) and goes on down the order" do
      with_config(yaml) do |path, dir|
        result = nil
        expect { result = resolve(path, dir, "work:qwen", env: { "SAMAGOTCHI_THINKING_LEVEL" => "on" }) }
          .to output(/SAMAGOTCHI_THINKING_LEVEL: thinking must be one of/).to_stderr
        expect(result).to eq([:off, "models: qwen"])
      end
    end
  end

  describe ".session_level" do
    it "takes off, low, medium and high as symbols or words; default and anything else are none, without a warning" do
      expect([:off, "Low", " medium ", :high].map { |v| described_class.session_level(v) }).to eq(%i[off low medium high])
      expect { expect([:default, "default", "turbo", nil, 3].map { |v| described_class.session_level(v) }).to all(be_nil) }
        .not_to output.to_stderr
    end
  end

  describe ".chat_fields" do
    it "sends both switches for off, reasoning_effort for an effort, nothing for default" do
      expect(described_class.chat_fields(:off)).to eq(chat_template_kwargs: { enable_thinking: false }, reasoning_effort: "none")
      expect(described_class.chat_fields(:low)).to eq(reasoning_effort: "low")
      expect(described_class.chat_fields(:high)).to eq(reasoning_effort: "high")
      expect(described_class.chat_fields(:default)).to eq({})
    end
  end

  describe ".native" do
    let(:qwen) { Samagotchi::ModelProfile.qwen36 }
    let(:gemma) { Samagotchi::ModelProfile.gemma4 }

    it "leaves the Gemma think token out for off, and prefills an empty thought channel" do
      expect(described_class.native(:off, gemma).system_token).to eq("")
      expect(described_class.native(:default, gemma).system_token).to eq("<|think|>\n")
      expect(described_class.native(:off, gemma).prefill).to eq("<|channel>thought\n<channel|>")
      expect(described_class.native(:default, gemma).prefill).to eq("")
    end

    it "prefills an empty thought after the Qwen cue for off" do
      expect(described_class.native(:off, qwen).prefill).to eq("<think>\n\n</think>\n\n")
      expect(described_class.native(:default, qwen).prefill).to eq("")
      expect(described_class.native(:off, qwen).system_token).to eq("")
    end

    it "honours off and default, not an effort" do
      expect(described_class.native(:off, qwen).honoured).to be(true)
      expect(described_class.native(:default, gemma).honoured).to be(true)
      expect(described_class.native(:low, qwen).honoured).to be(false)
      expect(described_class.native(:high, gemma).honoured).to be(false)
      expect(described_class.native(:high, gemma).system_token).to eq("<|think|>\n")
    end
  end
end
