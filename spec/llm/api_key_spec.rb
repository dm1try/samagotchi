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

  it "never shows the environment it reads the key from" do
    [key.inspect, key.to_s, key.pretty_inspect].each do |text|
      expect(text).to include("BOX_KEY")
      expect(text).not_to include("sk-box-1")
      expect(text).not_to include("sk-other-2")
    end
  end
end
