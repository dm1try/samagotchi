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

      expect(registry.list_all_models.values.map { |r| r[:models] }).to all(eq([{ "id" => "m" }]))
    end
  end
end
