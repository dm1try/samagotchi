# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/model_profile"
require "samagotchi/model_list_store"

# Warning about a model id the host's last saved list doesn't have, at
# spawn time: the session still starts (some hosts serve ids they don't
# list: a one-model llama.cpp server takes any name, OpenRouter's :nitro).
RSpec.describe Samagotchi::ModelProfile, ".model_warning" do
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

  # model_warning re-lists the host on a MISS (a saved list that lacks the
  # id) when that list is older than ModelProfile::RELIST_AFTER_SECONDS: the
  # network. These examples are mostly about the saved list itself, so the
  # default re-list answers nothing (a failed re-list: the warning comes
  # from the saved list, as before). Examples that test the re-list pass
  # their own.
  def check(name, relist: ->(*_args) {}, **kwargs)
    described_class.model_warning(name, hosts: hosts, relist: relist, **kwargs)
  end

  # What model_warning's relist: callable is: takes the host name and the
  # env, returns the ids the host lists now (or nil: it listed nothing).
  def relist(ids) = ->(_name, _env) { ids }

  # A saved list old enough for a miss to re-list the host: younger than the
  # TTL (still evidence) and older than ModelProfile::RELIST_AFTER_SECONDS.
  def saved_a_while_ago = Time.now.to_i - Samagotchi::ModelProfile::RELIST_AFTER_SECONDS - 60

  it "says nothing for a host's id that its saved list has" do
    save("box", %w[gemma-small qwen3])

    expect(check("box:gemma-small")).to be_nil
    expect(check("box:qwen3")).to be_nil
  end

  it "says nothing and never re-lists for an id the host declares under hosts.<name>.models" do
    save("box", %w[gemma-small], at: saved_a_while_ago)
    hosts["box"] = { models: Samagotchi::HostModel.parse_map(%w[rr/X], "box") }
    relist = ->(*_args) { raise "re-listed" }

    expect(check("box:rr/x", relist: relist)).to be_nil
    expect(check("box:rr/y", relist: ->(*_args) {})).to start_with("host 'box' doesn't list model 'rr/y'")
  end

  it "matches an id by case, as routing does" do
    save("box", %w[gemma-small])

    expect(check("box:GEMMA-SMALL")).to be_nil
  end

  it "warns about an id the host's list doesn't have, with a did-you-mean" do
    save("box", %w[gemma-small gemma-smal3 qwen3])

    expect(check("box:gemma-smal"))
      .to eq("host 'box' doesn't list model 'gemma-smal' (did you mean: gemma-smal3, gemma-small?); " \
             "started it anyway; `chi models` lists what the hosts serve")
  end

  it "says nothing more when no id is close" do
    save("box", %w[gemma-small])

    expect(check("box:zzzzzzzz"))
      .to eq("host 'box' doesn't list model 'zzzzzzzz'; started it anyway; `chi models` lists what the hosts serve")
  end

  it "names the id without the host prefix in the message" do
    save("box", %w[org/model])

    expect(check("box:org/model-2")).to start_with("host 'box' doesn't list model 'org/model-2'")
  end

  it "checks an alias's resolved id, not the alias" do
    save("box", %w[gemma-small])

    expect(check("box:small")).to be_nil
    expect(check("box:smaller")).to include("doesn't list")
  end

  it "warns about an alias whose target names a host and an unknown id" do
    save("box", %w[gemma-small])
    File.write(File.join(config_home, "samagotchi", "config.yml"), "#{config}  typo: box:nosuch\n")
    Samagotchi::Config.reload!(cli_overrides: {})

    expect(check("typo")).to start_with("host 'box' doesn't list model 'nosuch'")
  end

  it "checks nothing for a ref that names no host, even when its id is in no list" do
    save("main", %w[local-model])

    # A bare id goes to whichever host lists it (HostRegistry#host_for_model),
    # so one host's list alone can't judge it.
    expect(check("locl-model")).to be_nil
    expect(check("anything-at-all")).to be_nil
    expect(check("gemma-small")).to be_nil
  end

  it "checks nothing for an alias that resolves to no host" do
    save("main", %w[gemma-small])

    expect(check("plain")).to be_nil
  end

  it "checks nothing for a bare id whose ':' is an Ollama-style tag" do
    save("box", %w[gemma-small])

    %w[qwen3:8b mistral:7b openai/gpt-4o:free].each { |name| expect(check(name)).to be_nil }
  end

  it "checks nothing without a saved list for that host" do
    save("main", %w[local-model])

    %w[box:anything box:org/model1 box:nosuch].each { |name| expect(check(name)).to be_nil }
  end

  it "checks nothing without any saved list" do
    expect(check("box:nosuch")).to be_nil
    expect(check("locl-model")).to be_nil
  end

  it "passes every id of a stale list (a week old: the host may have changed)" do
    save("box", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS - 60)

    expect(check("box:nosuch")).to be_nil
  end

  it "checks a list saved exactly at the TTL (not stale yet)" do
    save("box", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS)

    expect(check("box:nosuch")).to include("doesn't list")
  end

  it "never re-lists a host it already knows (a hit in the saved list, no network on this path)" do
    require "samagotchi/client"
    save("box", %w[gemma-small])
    allow_any_instance_of(Samagotchi::Client).to receive(:list_models).and_raise("a host was asked")

    expect(check("box:gemma-small", relist: ->(*_args) { raise "a host was asked" })).to be_nil
    expect(check("box:GEMMA-SMALL", relist: ->(*_args) { raise "a host was asked" })).to be_nil
  end

  it "never re-lists a host with no saved list" do
    save("main", %w[local-model])
    expect(check("box:nosuch", relist: ->(*_args) { raise "a host was asked" })).to be_nil
  end

  it "never re-lists a stale saved list (a week old: it is no evidence either way)" do
    save("box", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS - 60)
    expect(check("box:nosuch", relist: ->(*_args) { raise "a host was asked" })).to be_nil
  end

  it "never re-lists for a ref that names no host (a bare id no single list can judge)" do
    save("box", %w[gemma-small])
    expect(check("locl-model", relist: ->(*_args) { raise "a host was asked" })).to be_nil
  end

  it "never re-lists a saved list from the last minutes (a miss warns from it at once)" do
    save("box", %w[gemma-small])

    expect(check("box:nosuch", relist: ->(*_args) { raise "a host was asked" }))
      .to eq("host 'box' doesn't list model 'nosuch'; started it anyway; `chi models` lists what the hosts serve")
    expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[gemma-small])
  end

  it "says nothing and updates the saved list when the re-list lists the typed id (the host was reloaded)" do
    save("box", %w[gemma-small], at: saved_a_while_ago)

    expect(check("box:incoai/Qwen3.8-27B-Splash", relist: relist(%w[incoai/Qwen3.8-27B-Splash gemma-small]))).to be_nil
    expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[incoai/Qwen3.8-27B-Splash gemma-small])
  end

  it "warns from the re-list's ids (with its did-you-mean) when the re-list still lacks the id" do
    save("box", %w[stale-model], at: saved_a_while_ago)

    expect(check("box:gemma-smal", relist: relist(%w[gemma-small qwen3])))
      .to eq("host 'box' doesn't list model 'gemma-smal' (did you mean: gemma-small?); " \
             "started it anyway; `chi models` lists what the hosts serve")
    expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[gemma-small qwen3])
  end

  it "warns from the saved list when the re-list fails" do
    save("box", %w[gemma-small gemma-smal3], at: saved_a_while_ago)

    expect(check("box:gemma-smal", relist: ->(*_args) { raise "connection refused" }))
      .to eq("host 'box' doesn't list model 'gemma-smal' (did you mean: gemma-smal3, gemma-small?); " \
             "started it anyway; `chi models` lists what the hosts serve")
    expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[gemma-small gemma-smal3])
  end

  it "warns from the saved list and keeps it when the re-list returns nothing" do
    save("box", %w[gemma-small], at: saved_a_while_ago)

    expect(check("box:nosuch", relist: relist(nil)))
      .to eq("host 'box' doesn't list model 'nosuch'; started it anyway; `chi models` lists what the hosts serve")
    expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[gemma-small])
  end

  it "takes a store to read (ModelListStore by default)" do
    at = Time.now.to_i
    store = Class.new do
      define_singleton_method(:read) { |**| { "box" => Samagotchi::ModelListStore::Saved.new(host: "box", ids: ["gemma-small"], at: at) } }
    end

    expect(check("box:gemma-small", lists: store)).to be_nil
    expect(check("box:nosuch", lists: store)).to include("doesn't list")
  end

  it "checks nothing when the store's file is unreadable" do
    FileUtils.mkdir_p(File.dirname(Samagotchi::ModelListStore.path))
    File.write(Samagotchi::ModelListStore.path, "{bad")

    expect(check("box:nosuch")).to be_nil
  end
end
