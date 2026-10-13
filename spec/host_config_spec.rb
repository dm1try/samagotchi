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

    it "reads steer_cut_after, 0 included, and warns about a bad value" do
      expect(described_class.parse("slow", { host: "h", "steer_cut_after" => 0 })).to have_attributes(steer_cut_after: 0)
      expect(described_class.parse("fast", { host: "h", "steer_cut_after" => "15" })).to have_attributes(steer_cut_after: 15)

      host = nil
      expect { host = described_class.parse("odd", { "host" => "h", "steer_cut_after" => 1.5 }) }
        .to output(/hosts entry 'odd': steer_cut_after must be whole seconds/).to_stderr
      expect(host).to have_attributes(name: "odd", steer_cut_after: nil)
    end
  end

  describe "api: anthropic" do
    it "talks to Anthropic's own API when the entry has no url or host" do
      host = described_class.parse("claude", { "api" => "anthropic", "api_key_env" => "ANTHROPIC_API_KEY" })

      expect(host).to have_attributes(api: :anthropic, url: "https://api.anthropic.com", host: "api.anthropic.com",
                                      port: 443, scheme: "https")
    end

    it "keeps a configured url or host, and still says host is required for any other api" do
      expect(described_class.parse("splash", { "api" => "anthropic", "url" => "http://box.lan:8082" }))
        .to have_attributes(url: "http://box.lan:8082", host: "box.lan")
      expect(described_class.parse("lan", { "api" => "anthropic", "host" => "box.lan", "port" => 8082 }))
        .to have_attributes(url: nil, host: "box.lan", port: 8082)
      expect { expect(described_class.parse("oai", { "api" => "openai" })).to be_nil }
        .to output(/hosts entry 'oai': host is required/).to_stderr
    end
  end

  describe "auth" do
    it "reads bearer and x-api-key as the ApiKey scheme, nil when unset" do
      expect(described_class.parse("a", { "host" => "h", "auth" => "Bearer" }).auth).to eq(:bearer)
      expect(described_class.parse("b", { "host" => "h", "auth" => " x-api-key " }).auth).to eq(:x_api_key)
      expect(described_class.parse("c", { "host" => "h" }).auth).to be_nil
    end

    it "ignores the entry, warning, for another value" do
      expect { expect(described_class.parse("odd", { "host" => "h", "auth" => "basic" })).to be_nil }
        .to output(/ignoring hosts entry 'odd': auth must be one of bearer, x-api-key/).to_stderr
    end

    it "warns once that it does nothing without api_key_env" do
      expect { described_class.parse("nokey", { "host" => "h", "auth" => "bearer" }) }
        .to output(/hosts entry 'nokey': auth has no effect without api_key_env/).to_stderr
      expect { described_class.parse("keyed", { "host" => "h", "auth" => "bearer", "api_key_env" => "K" }) }
        .not_to output.to_stderr
    end

    it "is a known hosts key (no unknown-key warning)" do
      expect(Samagotchi::Config::MAP_ENTRY_KEYS["hosts"]).to include("auth")
    end
  end

  describe "config" do
    it "knows steer_cut_after as a host and model key (no unknown-key warning)" do
      data = { "hosts" => { "w" => { "host" => "h", "steer_cut_after" => 0 } },
               "models" => { "q" => { "steer_cut_after" => 90 } } }
      expect(Samagotchi::Config.validate_yaml_sections(data)).to eq([])
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
        "api_key_env" => "GW_KEY", "auth" => "x-api-key", "profile" => "Qwen36", "first_token_timeout" => 90, "vision" => true,
        "sampling" => { "temperature" => 0.6, "chat_template_kwargs" => { "enable_thinking" => false } },
        "thinking" => "off", "reasoning_history" => "all", "remote" => false, "window_tokens" => 65_536,
        "steer_cut_after" => 0,
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

    it "gives a worker an api: anthropic entry with its default url and auth: bearer" do
      claude = described_class.parse("claude", { "api" => "anthropic", "api_key_env" => "K", "auth" => "bearer" })

      expect(claude.to_env_h).to include("url" => "https://api.anthropic.com", "api" => "anthropic", "auth" => "bearer")
      expect(through_env(claude)).to eq(claude)
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

    it "carries a host's steer_cut_after to workers in SAMAGOTCHI_HOSTS_JSON (0 survives)" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "config.yml")
        File.write(path, "hosts:\n  slow:\n    host: h\n    steer_cut_after: 0\n")
        json = Samagotchi::ConfigFile.hosts_json_for_env(env: {}, path: path)
        hosts = Samagotchi::ConfigFile.hosts_config(env: { "SAMAGOTCHI_HOSTS_JSON" => json },
                                                    path: File.join(dir, "none.yml"))
        expect(hosts["slow"].steer_cut_after).to eq(0)
      end
    end
  end
end
