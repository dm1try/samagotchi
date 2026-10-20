# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/host_config"

# One hosts: entry as a value object (ConfigFile.hosts_config holds them).
RSpec.describe Samagotchi::HostConfig do
  before { Samagotchi::ConfigFile.reset_warnings! }

  describe "constants" do
    it "defines host configuration constants on HostConfig" do
      expect(Samagotchi.const_defined?(:ANTHROPIC_URL, false)).to be(false)
      expect(Samagotchi.const_defined?(:AUTH_SCHEMES, false)).to be(false)
      expect(described_class::ANTHROPIC_URL).to eq("https://api.anthropic.com")
      expect(described_class::AUTH_SCHEMES).to eq("bearer" => :bearer, "x-api-key" => :x_api_key)
    end
  end

  describe ".parse" do
    it "reads string or symbol keys, lowercases the name and leaves unset fields nil (models {})" do
      host = described_class.parse("Box", { host: "box.lan", "port" => "8081", "api" => "OpenAI" })
      expect(host).to have_attributes(name: "box", host: "box.lan", port: 8081, scheme: "http", url: nil,
                                      api: :openai, api_key_env: nil, profile: nil,
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

  describe "dialect" do
    it "reads a known dialect on an api: anthropic entry, nil when unset" do
      expect(described_class.parse("fw", { "api" => "anthropic", "url" => "https://fw.test", "dialect" => "Fireworks" }).dialect)
        .to eq("fireworks")
      expect(described_class.parse("claude", { "api" => "anthropic" }).dialect).to be_nil
    end

    it "keeps the entry and ignores the dialect, warning once, when unknown or on another api" do
      expect { expect(described_class.parse("odd", { "api" => "anthropic", "dialect" => "splash" }).dialect).to be_nil }
        .to output(/hosts entry 'odd': dialect must be one of standard, fireworks; ignored/).to_stderr
      expect { expect(described_class.parse("oai", { "api" => "openai", "host" => "h", "dialect" => "fireworks" }).dialect).to be_nil }
        .to output(/hosts entry 'oai': dialect has no effect on api: openai; ignored/).to_stderr
    end

    it "is a known hosts key (no unknown-key warning)" do
      expect(Samagotchi::Config::MAP_ENTRY_KEYS["hosts"]).to include("dialect")
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
end
