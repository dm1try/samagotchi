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

    it "routes by alias and sends the alias's target" do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "small" => "box:gemma-small" })
      target = registry.resolve("small")

      expect(target.entry.name).to eq("box")
      expect(target.bare_model).to eq("gemma-small")
      expect(target.model).to eq("small")
    end

    it "gives each host's client the host's config name, for its error lines" do
      expect(registry.entries["box"].client.host_name).to eq("box")
      expect(registry.entries["default"].client.host_name).to eq("default")
    end

    it "keeps one client per host, so per-client caches (the /props window) survive" do
      expect(registry.resolve("box:a").client).to be(registry.resolve("box:b").client)
    end
  end

  describe "a bare id declared under hosts.<name>.models" do
    def declared(*ids) = Samagotchi::HostModel.parse_map(ids, "spec")

    let(:registry) do
      described_class.new(hosts_config: {
        "default" => { host: "localhost", port: 8080 },
        "box" => { host: "box.test", port: 8081 },
        "work" => { host: "gateway.example", port: 443, models: declared("rr/X", "rr/shared") },
        "other" => { host: "other.example", port: 443, models: declared("rr/shared") }
      })
    end

    before { allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({}) }

    def list(hosts_ids)
      allow(registry).to receive(:list_models_for) do |entry|
        Array(hosts_ids[entry.name]).map { |id| Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {}) }
      end
      registry.list_all_models
    end

    it "goes to the declaring host before any /models, by case, sent as typed" do
      target = registry.resolve("RR/x")

      expect(target.entry.name).to eq("work")
      expect(target.bare_model).to eq("RR/x")
    end

    it "goes to the first declaring host in hosts: order, and to the default host when it is one" do
      expect(registry.resolve("rr/shared").entry.name).to eq("work")

      list("default" => ["rr/shared"])
      expect(registry.resolve("rr/shared").entry.name).to eq("default")
    end

    it "goes to the default host when it declares the id too, whatever the hosts: order" do
      declaring_default = described_class.new(hosts_config: {
        "work" => { host: "gateway.example", port: 443, models: declared("rr/both") },
        "default" => { host: "localhost", port: 8080, models: declared("rr/both") }
      })

      expect(declaring_default.resolve("rr/both").entry.name).to eq("default")
    end

    it "orders listing and declaring hosts alike, by hosts: order" do
      list("box" => ["rr/x"])

      expect(registry.resolve("rr/x").entry.name).to eq("box")
      expect(registry.resolve("rr/shared").entry.name).to eq("work")
    end

    it "leaves a host-qualified ref alone" do
      expect(registry.resolve("other:rr/x").entry.name).to eq("other")
      expect(registry.resolve("box:rr/shared").entry.name).to eq("box")
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

    it "logs a host whose list failed, and lists the others" do
      allow(registry.adapter_for(registry.entries["oai"])).to receive(:list_models).and_raise(Errno::ECONNREFUSED)
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      results = registry.list_all_models

      expect(results["oai"]).to include(models: [], error: a_string_including("Connection refused"))
      expect(results["box"][:models].map(&:id)).to eq(["gemma-4-26b"])
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:model, "list_failed", hash_including(host: "oai", error: "Errno::ECONNREFUSED"))
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
      first = registry.adapter_for(registry.entries["fw"])
      expect(registry.adapter_for(registry.entries["fw"])).to be(first)
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

  describe "#list_all_models(wait:)" do
    let(:registry) do
      described_class.new(hosts_config: {
        "default" => { host: "localhost", port: 8080 },
        "slow" => { host: "slow.test", port: 8081 }
      })
    end
    let(:release) { Queue.new }

    before do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({})
      allow(registry.entries["default"].client).to receive(:list_models).and_return([{ "id" => "fast-model" }])
      allow(registry.entries["slow"].client).to receive(:list_models) do
        release.pop
        [{ "id" => "late-model" }]
      end
    end

    after { release << :go }

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    it "answers within the wait: a stalled host reports no answer, the others list" do
      started = mono
      results = registry.list_all_models(wait: 0.1)

      expect(mono - started).to be < 0.5
      expect(results["default"][:models].map(&:id)).to eq(["fast-model"])
      expect(results["slow"]).to include(models: [], error: "no answer in 0.1 s")
    end

    it "returns a snapshot a late thread doesn't change, and stores no partial listing" do
      results = registry.list_all_models(wait: 0.05)
      release << :go
      sleep 0.1

      expect(results["slow"][:error]).to eq("no answer in 0.05 s")
      expect(registry.cached_results).to be_nil
      expect(registry.resolve("late-model").entry.name).to eq("default")
    end

    it "waits for every host and stores the listing when all answer in time" do
      release << :go
      results = registry.list_all_models(wait: 2)

      expect(results["slow"][:models].map(&:id)).to eq(["late-model"])
      expect(registry.cached_results).to eq(results)
      expect(registry.resolve("late-model").entry.name).to eq("slow")
    end
  end

  describe "#list_models (one host, for the spawn-time model check)" do
    let(:registry) do
      described_class.new(hosts_config: {
        "box" => { host: "box.test", port: 8081 },
        "oai" => { host: "oai.test", port: 8000, api: :openai }
      })
    end
    let(:state_home) { Dir.mktmpdir("model-check-registry") }
    let(:config_home) { Dir.mktmpdir("model-check-registry-config") }

    around do |example|
      with_env("XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => config_home) do
        Samagotchi::Config.reload!(cli_overrides: {})
        example.run
      ensure
        Samagotchi::Config.reload!(cli_overrides: {})
      end
    end

    before do
      allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({})
      allow(registry.entries["box"].client).to receive(:list_models)
        .and_return([{ "id" => "gemma-4-26b", "status" => "loaded" }])
      allow(registry.adapter_for(registry.entries["oai"])).to receive(:list_models)
        .and_return([Samagotchi::LLM::ModelInfo.new(id: "qwen-local", context_window: 32_768, supports_tools: nil, raw: {})])
    end

    after { FileUtils.rm_rf([state_home, config_home]) }

    it "lists only the named host (the adapter for a chat host, the client for a raw one) and saves it to the store" do
      expect(registry.list_models("box")).to eq(["gemma-4-26b"])
      expect(registry.list_models("oai")).to eq(["qwen-local"])

      expect(Samagotchi::ModelListStore.find("box").ids).to eq(%w[gemma-4-26b])
      expect(Samagotchi::ModelListStore.find("oai").ids).to eq(%w[qwen-local])
    end

    it "asks nothing for a name with no host (nothing is saved), and returns nil when the host fails to list" do
      expect(registry.list_models("nosuch")).to be_nil
      expect(registry.list_models(nil)).to be_nil
      expect(Samagotchi::ModelListStore.find("box")).to be_nil

      allow(registry.entries["box"].client).to receive(:list_models).and_raise("connection refused")
      expect(registry.list_models("box")).to be_nil
      expect(Samagotchi::ModelListStore.find("box")).to be_nil
    end
  end
end
