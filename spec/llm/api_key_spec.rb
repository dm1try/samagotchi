# frozen_string_literal: true

require "pp"
require "net/http"
require "samagotchi/llm/api_key"

RSpec.describe Samagotchi::LLM::ApiKey do
  let(:env) { { "BOX_KEY" => "sk-box-1", "OTHER_SECRET" => "sk-other-2" } }
  let(:key) { described_class.for("BOX_KEY", host: "box", env: env) }

  it "is nil for a host without api_key_env" do
    expect(described_class.for(nil, host: "box")).to be_nil
    expect(described_class.for("  ", host: "box")).to be_nil
  end

  # Anthropic's Messages API refuses a request that carries both headers.
  describe "#authorize" do
    def headers_after(scheme)
      request = Net::HTTP::Post.new(URI("http://box.test/v1/messages"))
      described_class.for("BOX_KEY", host: "box", env: env, scheme: scheme).authorize(request)
      request.to_hash.slice("authorization", "x-api-key")
    end

    it "sets exactly one auth header per scheme: Bearer by default, x-api-key when asked" do
      expect(headers_after(nil)).to eq("authorization" => ["Bearer sk-box-1"])
      expect(headers_after(:bearer)).to eq("authorization" => ["Bearer sk-box-1"])
      expect(headers_after(:x_api_key)).to eq("x-api-key" => ["sk-box-1"])
    end

    it "refuses an unknown scheme" do
      expect { described_class.for("BOX_KEY", host: "box", env: env, scheme: :basic) }.to raise_error(ArgumentError)
    end

    it "raises AuthError naming the variable when it is not set, whatever the scheme" do
      key = described_class.for("NOPE_KEY", host: "box", env: env, scheme: :x_api_key)

      expect { key.authorize(Net::HTTP::Get.new(URI("http://box.test/"))) }
        .to raise_error(Samagotchi::LLM::AuthError, /set NOPE_KEY/)
    end
  end

  describe "the Keychain fallback" do
    let(:keychain) { Struct.new(:items) { def read(name) = items[name] }.new({ "NOPE_KEY" => "sk-keychain-3" }) }

    before { Samagotchi::HostKeys.keychain = keychain }

    it "sends the Keychain's key when the variable is unset, and the hint says where it came from" do
      request = Net::HTTP::Get.new(URI("http://box.test/"))
      key = described_class.for("NOPE_KEY", host: "box", env: env)
      key.authorize(request)

      expect(request["Authorization"]).to eq("Bearer sk-keychain-3")
      expect(key.hint).to eq("check NOPE_KEY (from the Keychain) (the API key for host box)")
      expect(described_class.for("BOX_KEY", host: "box", env: env).hint).to eq("check BOX_KEY (the API key for host box)")
      expect(key.inspect).not_to include("sk-keychain-3")
    end

    it "names the Keychain in the unset error and the missing-key hint where it is read" do
      allow(Samagotchi::HostKeys).to receive(:available?).and_return(true)
      key = described_class.for("ALSO_UNSET", host: "box", env: env)

      expect { key.authorize(Net::HTTP::Get.new(URI("http://box.test/"))) }
        .to raise_error(Samagotchi::LLM::AuthError, "box: set ALSO_UNSET (the API key for host box) or store it in the " \
                                                   "Keychain: security add-generic-password -s chi -a ALSO_UNSET -w")
      expect(described_class.missing_hint("box")).to include("an environment variable (or the Keychain)")
    end

    it "keeps the plain wording where the Keychain is not read (Linux, SAMAGOTCHI_KEYCHAIN=off)" do
      allow(Samagotchi::HostKeys).to receive(:available?).and_return(false)
      key = described_class.for("ALSO_UNSET", host: "box", env: env)

      expect { key.authorize(Net::HTTP::Get.new(URI("http://box.test/"))) }
        .to raise_error(Samagotchi::LLM::AuthError, "box: set ALSO_UNSET (the API key for host box)")
      expect(described_class.missing_hint("box")).not_to include("Keychain")
    end
  end

  it "never shows the environment it reads the key from" do
    [key.inspect, key.to_s, key.pretty_inspect].each do |text|
      expect(text).to include("BOX_KEY")
      expect(text).not_to include("sk-box-1")
      expect(text).not_to include("sk-other-2")
    end
  end
end
