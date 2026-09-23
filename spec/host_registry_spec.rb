# frozen_string_literal: true

require "samagotchi/host_registry"

RSpec.describe Samagotchi::HostRegistry do
  let(:registry) do
    described_class.new(hosts_config: {
      "default" => { host: "localhost", port: 8080 },
      "box" => { host: "box.test", port: 8081 }
    })
  end

  describe "#resolve" do
    before { allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({}) }

    it "routes a host-qualified model to its host and strips the prefix" do
      target = registry.resolve("box:gemma4-26b")

      expect(target.entry.name).to eq("box")
      expect(target.bare_model).to eq("gemma4-26b")
      expect(target.client).to be(registry.entries["box"].client)
      expect(target.root_url).to eq("http://box.test:8081")
      expect(target.openai_base_url).to eq("http://box.test:8081/v1")
    end

    it "sends an unqualified model to the default host as is" do
      target = registry.resolve("Gemma-4B-it")

      expect(target.entry.name).to eq("default")
      expect(target.bare_model).to eq("Gemma-4B-it")
      expect(target.model).to eq("Gemma-4B-it")
    end

    it "routes by alias but keeps the name it was given (as Engine always did)" do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "small" => "box:gemma4-small" })
      target = registry.resolve("small")

      expect(target.entry.name).to eq("box")
      expect(target.bare_model).to eq("small")
    end

    it "keeps one client per host, so per-client caches (the /props window) survive" do
      expect(registry.resolve("box:a").client).to be(registry.resolve("box:b").client)
    end
  end

  describe "client_override" do
    let(:stub) { double("client") }

    it "is the client of every target and of client_for_model" do
      registry.client_override = stub

      expect(registry.resolve("box:gemma4-26b").client).to be(stub)
      expect(registry.resolve("Gemma-4B-it").client).to be(stub)
      expect(registry.client_for_model("box:x").first).to be(stub)
    end

    it "is used to list models" do
      registry.client_override = stub
      allow(stub).to receive(:list_models).and_return([{ "id" => "m" }])

      expect(registry.list_all_models.values.map { |r| r[:models].map(&:id) }).to all(eq(["m"]))
    end
  end

  describe "model lists from each host's adapter" do
    let(:registry) do
      described_class.new(hosts_config: {
        "box" => { name: "box", host: "box.test", port: 8081 },
        "oai" => { name: "oai", host: "oai.test", port: 8000, api: :openai },
        "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                  url: "https://api.example.test/v1", api_key_env: "FW_KEY" }
      }, clock: -> { clock.first })
    end
    let(:clock) { [1000.0] }

    before do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({})
      allow(registry.entries["box"].client).to receive(:list_models)
        .and_return([{ "id" => "gemma-4-26b", "status" => "loaded" }])
      allow(registry.adapter_for(registry.entries["oai"])).to receive(:list_models)
        .and_return([Samagotchi::LLM::ModelInfo.new(id: "qwen-local", context_window: 32_768, supports_tools: nil, raw: {})])
      allow(registry.adapter_for(registry.entries["fw"])).to receive(:list_models)
        .and_return([Samagotchi::LLM::ModelInfo.new(id: "accounts/x/models/llama-v3", context_window: 131_072, supports_tools: true, raw: {})])
    end

    it "lists every host's models as ModelInfo, raw hosts' hashes included" do
      results = registry.list_all_models

      expect(results["box"][:models].first).to have_attributes(id: "gemma-4-26b", raw: { "id" => "gemma-4-26b", "status" => "loaded" })
      expect(results["oai"][:models].map(&:id)).to eq(["qwen-local"])
      expect(results["fw"][:models].first.context_window).to eq(131_072)
    end

    it "calls a host remote when it has an API key variable or an https url" do
      expect(registry.entries.transform_values(&:remote?)).to eq("box" => false, "oai" => false, "fw" => true)
    end

    it "routes to a remote host only by exact id, never by a substring" do
      registry.list_all_models

      expect(registry.resolve("accounts/x/models/llama-v3").entry.name).to eq("fw")
      expect(registry.resolve("llama-v3").entry.name).not_to eq("fw")
      expect(registry.resolve("gemma-4").entry.name).to eq("box")
    end

    it "keeps one adapter per host, which remembers a remote list for 10 minutes and a local one for a minute" do
      expect(registry.adapter_for(registry.entries["fw"])).to be(registry.adapter_for(registry.entries["fw"]))
      expect(registry.adapter_for(registry.entries["fw"]).models_ttl).to eq(600)
      expect(registry.adapter_for(registry.entries["oai"]).models_ttl).to eq(60)
    end

    it "limits the wait for a first token on remote hosts only, unless configured" do
      expect(registry.entries.transform_values(&:first_token_limit)).to eq("box" => nil, "oai" => nil, "fw" => 120)
      expect(registry.adapter_for(registry.entries["fw"]).first_token_timeout).to eq(120)
      expect(registry.adapter_for(registry.entries["oai"]).first_token_timeout).to be_nil
    end

    it "takes the host's first_token_timeout, then server.first_token_timeout; 0 turns it off" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("server.first_token_timeout").and_return(30)
      configured = described_class.new(hosts_config: {
        "box" => { name: "box", host: "box.test", port: 8081, first_token_timeout: 200 },
        "oai" => { name: "oai", host: "oai.test", port: 8000, api: :openai },
        "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                  url: "https://api.example.test/v1", api_key_env: "FW_KEY", first_token_timeout: 0 }
      })

      expect(configured.entries.transform_values(&:first_token_limit)).to eq("box" => 200, "oai" => 30, "fw" => nil)
      expect(configured.entries["box"].client.first_token_timeout).to eq(200)
    end

    it "reuses a host's list within its TTL unless forced" do
      registry.list_all_models
      clock[0] += 120

      registry.list_all_models(force: false)

      expect(registry.adapter_for(registry.entries["fw"])).to have_received(:list_models).once
      expect(registry.entries["box"].client).to have_received(:list_models).twice
    end
  end
end
