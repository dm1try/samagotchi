# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/host_config"

# One hosts: entry as a value object (ConfigFile.hosts_config holds them).
RSpec.describe Samagotchi::HostConfig do
  before { Samagotchi::ConfigFile.reset_warnings! }

  describe ".parse" do
    it "reads string or symbol keys, lowercases the name and leaves unset fields nil (models {})" do
      host = described_class.parse("Box", { host: "box.lan", "port" => "8081", "api" => "OpenAI" })
      expect(host).to have_attributes(name: "box", host: "box.lan", port: 8081, scheme: "http", url: nil,
                                      api: :openai, transport: nil, api_key_env: nil, profile: nil,
                                      thinking: nil, models: {})
    end

    it "is nil for a disabled entry, without a warning" do
      expect { expect(described_class.parse("off", { "host" => "h", "enabled" => "False" })).to be_nil }
        .not_to output.to_stderr
    end

    it "warns once, naming the entry, and is nil for an invalid one" do
      expect { expect(described_class.parse("bad name", { "host" => "h" })).to be_nil }
        .to output(%r{ignoring hosts entry 'bad name': must match /\[a-z0-9\]}).to_stderr
      expect { expect(described_class.parse("box", "h")).to be_nil }
        .to output(/ignoring hosts entry 'box': expected mapping/).to_stderr
      expect { expect(described_class.parse("box", { "host" => "h", "api" => "grpc" })).to be_nil }
        .to output(/ignoring hosts entry 'box': unknown api 'grpc'/).to_stderr
    end

    it "is nil for a blank name, without a warning" do
      expect { expect(described_class.parse(" ", { "host" => "h" })).to be_nil }.not_to output.to_stderr
    end
  end

  describe ".coerce" do
    it "takes a literal Hash of fields (specs) and keeps a HostConfig as it is" do
      host = described_class.coerce("Box", { host: "box.test", port: 8081, api: :openai })
      expect(host).to have_attributes(name: "box", host: "box.test", port: 8081, api: :openai, models: {})
      expect(described_class.coerce("box", host)).to be(host)
    end
  end

  # A worker gets its parent's hosts through SAMAGOTCHI_HOSTS_JSON. These
  # entries set every field, so a field added to HostConfig fails here
  # until the entry sets it (the nil check) and #to_env_h writes it (the
  # round trip).
  describe "#to_env_h" do
    let(:full) do
      { "url" => "https://gw.example.test/v1/", "api" => "openai", "transport" => "omlx",
        "api_key_env" => "GW_KEY", "profile" => "Qwen36", "first_token_timeout" => 90, "vision" => true,
        "sampling" => { "temperature" => 0.6, "chat_template_kwargs" => { "enable_thinking" => false } },
        "thinking" => "off", "remote" => false, "window_tokens" => 65_536,
        "llm_context_strategy" => %w[stale forget], "llm_context_apply" => "turn_end",
        "llm_context_budget_tokens" => "64k",
        "models" => { "rr/DeepSeek" => { "price" => { "input" => 0.27, "output" => 1.1 }, "served" => %w[ds-a] },
                      "rr/plain" => nil } }
    end

    def through_env(host) = described_class.parse(host.name, JSON.parse(JSON.generate(host.to_env_h)))

    it "sets every field in the fixture (a new field needs a value here)" do
      host = described_class.parse("gw", full)
      expect(described_class.members.select { |m| host.public_send(m).nil? }).to eq([])
    end

    it "gives a worker an equal HostConfig for a url entry and a host/port one" do
      url_host = described_class.parse("gw", full)
      expect(through_env(url_host)).to eq(url_host)

      local = described_class.parse("box", full.except("url").merge("host" => "box.lan", "port" => 8081))
      expect(local).to have_attributes(host: "box.lan", port: 8081, url: nil)
      expect(through_env(local)).to eq(local)
    end

    it "round-trips through ConfigFile.hosts_json_for_env and hosts_config" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, { "hosts" => { "gw" => full, "box" => { "host" => "box.lan" } } }.to_yaml)
        parent = Samagotchi::ConfigFile.hosts_config(env: {}, path: path)
        json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
        worker = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json },
                                                     path: File.join(dir, "none.yml"))
        expect(worker).to eq(parent)
      end
    end
  end
end
