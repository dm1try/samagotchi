# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/model_profile"
require "samagotchi/model_list_store"

# Refusing a model id the host's last saved list doesn't have, at spawn
# time: an unknown id used to spawn a worker whose first turn failed.
RSpec.describe Samagotchi::ModelProfile, ".check_model!" do
  let(:state_home) { Dir.mktmpdir("model-check") }
  let(:config_home) { Dir.mktmpdir("model-check-config") }
  let(:hosts) { { "main" => {}, "box" => {} } }
  let(:config) do
    <<~YAML
      default:
        model: box:gemma-small
      hosts:
        main: {host: localhost, port: 8080}
        box: {host: box.test, port: 8081}
      model_aliases:
        small: box:gemma-small
        plain: gemma-small
    YAML
  end

  around do |example|
    FileUtils.mkdir_p(File.join(config_home, "samagotchi"))
    File.write(File.join(config_home, "samagotchi", "config.yml"), config)
    with_env("XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => config_home, "SAMAGOTCHI_HOSTS_JSON" => nil) do
      Samagotchi::Config.reload!(cli_overrides: {})
      example.run
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end
  end

  after { FileUtils.rm_rf([state_home, config_home]) }

  def save(host, ids, at: Time.now.to_i)
    Samagotchi::ModelListStore.save(host, ids, at: at)
  end

  def check(name, **kwargs)
    described_class.check_model!(name, hosts: hosts, **kwargs)
  end

  it "passes a host's id that its saved list has, and returns the name" do
    save("box", %w[gemma-small qwen3])

    expect(check("box:gemma-small")).to eq("box:gemma-small")
    expect(check("box:qwen3")).to eq("box:qwen3")
  end

  it "matches an id by case, as routing does" do
    save("box", %w[gemma-small])

    expect(check("box:GEMMA-SMALL")).to eq("box:GEMMA-SMALL")
  end

  it "refuses an id the host's list doesn't have, with a did-you-mean" do
    save("box", %w[gemma-small gemma-smal3 qwen3])

    expect { check("box:gemma-smal") }
      .to raise_error(Samagotchi::ModelProfile::UnknownModel,
                      "unknown model 'gemma-smal' on host 'box' (did you mean: gemma-smal3, gemma-small?); " \
                      "`chi models` lists what the hosts serve")
  end

  it "says nothing more when no id is close" do
    save("box", %w[gemma-small])

    expect { check("box:zzzzzzzz") }
      .to raise_error(Samagotchi::ModelProfile::UnknownModel,
                      "unknown model 'zzzzzzzz' on host 'box'; `chi models` lists what the hosts serve")
  end

  it "names the id without the host prefix in the message" do
    save("box", %w[org/model])

    expect { check("box:org/model-2") }
      .to raise_error(Samagotchi::ModelProfile::UnknownModel, %r{\Aunknown model 'org/model-2' on host 'box'})
  end

  it "checks an alias's resolved id, not the alias" do
    save("box", %w[gemma-small])

    expect(check("box:small")).to eq("box:small")
    expect { check("box:smaller") }.to raise_error(Samagotchi::ModelProfile::UnknownModel)
  end

  it "refuses an alias whose target names a host and an unknown id" do
    save("box", %w[gemma-small])
    File.write(File.join(config_home, "samagotchi", "config.yml"), "#{config}  typo: box:nosuch\n")
    Samagotchi::Config.reload!(cli_overrides: {})

    expect { check("typo") }.to raise_error(Samagotchi::ModelProfile::UnknownModel, /unknown model 'nosuch' on host 'box'/)
  end

  it "checks nothing for a ref that names no host, even when its id is in no list" do
    save("main", %w[local-model])

    # A bare id goes to whichever host lists it (HostRegistry#host_for_model),
    # so one host's list alone can't judge it.
    expect(check("locl-model")).to eq("locl-model")
    expect(check("anything-at-all")).to eq("anything-at-all")
    expect(check("gemma-small")).to eq("gemma-small")
  end

  it "checks nothing for an alias that resolves to no host" do
    save("main", %w[gemma-small])

    expect(check("plain")).to eq("plain")
  end

  it "checks nothing for a bare id whose ':' is an Ollama-style tag" do
    save("box", %w[gemma-small])

    %w[qwen3:8b mistral:7b openai/gpt-4o:free].each { |name| expect(check(name)).to eq(name) }
  end

  it "checks nothing without a saved list for that host" do
    save("main", %w[local-model])

    %w[box:anything box:org/model1 box:nosuch].each { |name| expect(check(name)).to eq(name) }
  end

  it "checks nothing without any saved list" do
    expect(check("box:nosuch")).to eq("box:nosuch")
    expect(check("locl-model")).to eq("locl-model")
  end

  it "passes every id of a stale list (a week old: the host may have changed)" do
    save("box", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS - 60)

    expect(check("box:nosuch")).to eq("box:nosuch")
  end

  it "checks a list saved exactly at the TTL (not stale yet)" do
    save("box", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS)

    expect { check("box:nosuch") }.to raise_error(Samagotchi::ModelProfile::UnknownModel)
  end

  it "never asks a host (no network on this path)" do
    require "samagotchi/client"
    save("box", %w[gemma-small])
    allow_any_instance_of(Samagotchi::Client).to receive(:list_models).and_raise("a host was asked")

    expect(check("box:gemma-small")).to eq("box:gemma-small")
    expect { check("box:nosuch") }.to raise_error(Samagotchi::ModelProfile::UnknownModel)
  end

  it "takes a store to read (ModelListStore by default)" do
    at = Time.now.to_i
    store = Class.new do
      define_singleton_method(:read) { |**| { "box" => Samagotchi::ModelListStore::Saved.new(host: "box", ids: ["gemma-small"], at: at) } }
    end

    expect(check("box:gemma-small", lists: store)).to eq("box:gemma-small")
    expect { check("box:nosuch", lists: store) }.to raise_error(Samagotchi::ModelProfile::UnknownModel)
  end

  it "is a MissingModel, so every surface reporting a missing model reports it the same way" do
    save("box", %w[gemma-small])

    expect { check("box:nosuch") }.to raise_error(Samagotchi::ModelProfile::MissingModel)
  end

  it "checks nothing when the store's file is unreadable" do
    FileUtils.mkdir_p(File.dirname(Samagotchi::ModelListStore.path))
    File.write(Samagotchi::ModelListStore.path, "{bad")

    expect(check("box:nosuch")).to eq("box:nosuch")
  end
end
