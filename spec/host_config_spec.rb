# frozen_string_literal: true

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
end
