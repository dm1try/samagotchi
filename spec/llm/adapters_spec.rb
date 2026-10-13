# frozen_string_literal: true

require "samagotchi/llm/adapters"
require "samagotchi/host_registry"

RSpec.describe Samagotchi::LLM::Adapters do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "oai" => { host: "10.0.0.5", port: 8082, api: "openai" },
      "raw" => { host: "localhost", port: 8080 }
    }, env: {})
  end

  it "maps each chat-loop api to its adapter class" do
    expect(described_class::BY_API).to eq(openai: Samagotchi::LLM::OpenAIChat)
    expect(described_class.chat_api?(:openai)).to be(true)
    expect(described_class.chat_api?("openai")).to be(true)
    expect(described_class.chat_api?(nil)).to be(false)
    expect(described_class.chat_api?(:raw)).to be(false)
  end

  it "builds a host entry's adapter from its api, url, key and options" do
    adapter = described_class.for(registry.entries["oai"], models_ttl: 5, first_token_timeout: 7)

    expect(adapter).to be_a(Samagotchi::LLM::OpenAIChat)
    expect(adapter.base_url).to eq("http://10.0.0.5:8082/v1")
    expect(adapter.host_name).to eq("oai")
    expect(adapter.models_ttl).to eq(5)
    expect(adapter.first_token_timeout).to eq(7)
  end

  it "refuses an entry whose api has no chat adapter" do
    expect { described_class.for(registry.entries["raw"]) }.to raise_error(ArgumentError, /no chat adapter/)
  end

  it "builds an adapter by api from a base url, a name and a key (a side request's)" do
    adapter = described_class.build(api: :openai, base_url: "http://x.test/v1", host_name: "recap", api_key_env: "X_KEY",
                                    stream: false, retries: false)

    expect(adapter).to be_a(Samagotchi::LLM::OpenAIChat)
    expect([adapter.base_url, adapter.host_name, adapter.api_key_env]).to eq(["http://x.test/v1", "recap", "X_KEY"])
    expect { described_class.build(api: :raw, base_url: "http://x", host_name: "h") }.to raise_error(ArgumentError)
  end

  describe "the host entry" do
    it "is a chat host when its api is one of the adapters'" do
      expect(registry.entries["oai"].chat?).to be(true)
      expect(registry.entries["raw"].chat?).to be(false)
    end

    it "names the API base its adapter talks to (the OpenAI base for api: openai)" do
      expect(registry.entries["oai"].api_base_url).to eq("http://10.0.0.5:8082/v1")
      expect(registry.entries["oai"].api_base_url).to eq(registry.entries["oai"].openai_base_url)
    end
  end

  it "is what HostRegistry#adapter_for builds through" do
    allow(described_class).to receive(:for).and_call_original

    registry.adapter_for(registry.entries["oai"])

    expect(described_class).to have_received(:for).with(registry.entries["oai"], models_ttl: 60, first_token_timeout: nil)
  end
end
