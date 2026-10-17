# frozen_string_literal: true

require "spec_helper"
require "samagotchi/idle_target"
require "samagotchi/host_registry"
require "samagotchi/host_model"

# The side model's settings as a target (RecapSetup's cases are in
# engine_recap_host_spec and model_ref_spec; a broadcast's triage uses it too).
RSpec.describe Samagotchi::IdleTarget do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { name: "box", host: "box.test", port: 8081 },
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })
  end

  def resolve(model: nil, host_ref: nil, base_url: nil)
    described_class.resolve(model: model, host_ref: host_ref, base_url: base_url, host_registry: registry)
  end

  it "is nil when nothing is set, blanks included: the caller picks its default" do
    expect(resolve).to be_nil
    expect(resolve(model: " ", host_ref: "", base_url: nil)).to be_nil
  end

  it "pins a host by host_ref, by the model's own host prefix or by base_url" do
    expect(resolve(model: "small", host_ref: "fw").to_h)
      .to eq(base_url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY", model: "small", label: "small",
             api: :openai, auth: nil, dialect: nil, price: nil)
    expect(resolve(model: "box:small").to_h)
      .to eq(base_url: "http://box.test:8081/v1", api_key_env: nil, model: "small", label: "box:small", api: :openai,
             auth: nil, dialect: nil, price: nil)
    expect(resolve(model: "m", base_url: "http://other.test/v1 ").to_h)
      .to eq(base_url: "http://other.test/v1", api_key_env: nil, model: "m", label: "m", api: :openai, auth: nil, dialect: nil, price: nil)
  end

  # The api picks the side client's adapter (LLM::Adapters.build): a chat
  # host's own, else the OpenAI API a raw host's server also serves.
  describe "the api" do
    it "defaults to openai, so a target built from a url and a model keeps working" do
      target = described_class.new(base_url: "http://x/v1", api_key_env: nil, model: "m", label: "m")

      expect(target.api).to eq(:openai)
    end

    it "is the host entry's for a chat host, openai for a raw one" do
      fw = registry.entries["fw"]
      allow(fw).to receive_messages(api: :wire, chat?: true, api_base_url: "https://api.example.test/wire")

      expect(resolve(model: "small", host_ref: "fw")).to have_attributes(api: :wire, base_url: "https://api.example.test/wire")
      expect(resolve(model: "small", host_ref: "box")).to have_attributes(api: :openai, base_url: "http://box.test:8081/v1")
    end

    it "carries the host's auth: with its api, by host_ref and in of_model" do
      fw = registry.entries["fw"]
      allow(fw).to receive_messages(api: :wire, chat?: true, auth: :x_api_key)

      expect(resolve(model: "small", host_ref: "fw")).to have_attributes(api: :wire, auth: :x_api_key)
      expect(described_class.of_model(registry, "fw:small")).to have_attributes(api: :wire, auth: :x_api_key)
      expect(described_class.of_model(registry, "box:small").auth).to be_nil
    end

    it "carries the host's dialect with its api, by host_ref and in of_model" do
      fw = registry.entries["fw"]
      allow(fw).to receive_messages(api: :anthropic, chat?: true, dialect: "fireworks")

      expect(resolve(model: "small", host_ref: "fw")).to have_attributes(api: :anthropic, dialect: "fireworks")
      expect(described_class.of_model(registry, "fw:small")).to have_attributes(api: :anthropic, dialect: "fireworks")
      expect(described_class.of_model(registry, "box:small").dialect).to be_nil
    end

    it "comes from the model's host in of_model" do
      fw = registry.entries["fw"]
      allow(fw).to receive_messages(api: :wire, chat?: true, api_base_url: "https://api.example.test/wire")

      expect(described_class.of_model(registry, "fw:small"))
        .to have_attributes(api: :wire, base_url: "https://api.example.test/wire", model: "small", label: "fw:small")
      expect(described_class.of_model(registry, "box:small")).to have_attributes(api: :openai)
    end
  end

  # A side request's estimate (SessionMetrics::SideTotals) uses its target
  # host's models: price, by the id asked for, as a turn's does
  # (EffectiveModel#price).
  describe "the price" do
    let(:cheap) { Samagotchi::ModelPrice.new(input: 1.0, cache_read: 1.0, cache_write: 1.0, output: 2.0) }
    let(:dear) { Samagotchi::ModelPrice.new(input: 5.0, cache_read: 5.0, cache_write: 5.0, output: 9.0) }
    let(:registry) do
      Samagotchi::HostRegistry.new(hosts_config: {
        "box" => { name: "box", host: "box.test", port: 8081,
                   models: Samagotchi::HostModel.parse_map({ "small" => { "price" => { "input" => 5.0, "output" => 9.0 } } }, "box") },
        "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                  url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY",
                  models: Samagotchi::HostModel.parse_map({ "Acme/Small" => { "price" => { "input" => 1.0, "output" => 2.0 } } }, "fw") }
      })
    end

    it "is the host's models: price for the id asked for, case-insensitively" do
      expect(described_class.of_model(registry, "fw:acme/small").price).to eq(cheap)
      expect(resolve(model: "ACME/Small", host_ref: "fw").price).to eq(cheap)
    end

    it "is the other host's price for a model on another host" do
      expect(described_class.of_model(registry, "box:small").price).to eq(dear)
      expect(resolve(model: "box:small").price).to eq(dear)
    end

    it "is nil for a model the host prices not, and for a bare base_url target" do
      expect(described_class.of_model(registry, "fw:other").price).to be_nil
      expect(resolve(model: "small", base_url: "http://other.test/v1").price).to be_nil
      expect(described_class.new(base_url: "http://x/v1", api_key_env: nil, model: "m", label: "m").price).to be_nil
    end
  end

  it "says which setting is wrong when it can't be resolved" do
    expect { resolve(model: "m", host_ref: "nope") }
      .to raise_error(described_class::Unresolved) { |e| expect([e.reason, e.host_ref]).to eq([:host_ref_unknown, "nope"]) }
    expect { resolve(model: "box:m", host_ref: "fw") }
      .to raise_error(described_class::Unresolved) { |e| expect([e.reason, e.named]).to eq([:model_host_mismatch, "box"]) }
    expect { resolve(host_ref: "fw") }
      .to raise_error(described_class::Unresolved) { |e| expect(e.reason).to eq(:incomplete) }
  end

  it "tells a fixed host from a model alone, which goes where a bare --model goes" do
    expect(described_class.host_named?(model: "m", host_ref: nil, base_url: nil, host_registry: registry)).to be(false)
    expect(described_class.host_named?(model: "box:m", host_ref: nil, base_url: nil, host_registry: registry)).to be(true)
    expect(described_class.host_named?(model: "m", host_ref: "fw", base_url: nil, host_registry: registry)).to be(true)
    expect(resolve(model: "m")).to have_attributes(model: "m", label: "m")
  end
end
