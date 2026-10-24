# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/info_probe"

RSpec.describe Samagotchi::Web::InfoProbe do
  let(:http) { double("http") }
  let(:reply) { double("reply", code: "200", body: '{"app":"chi-web"}') }
  let(:public_url) { "https://4567.pod.test" }

  before do
    allow(Net::HTTP).to receive(:start).and_yield(http)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("web.public_url").and_return(public_url)
  end

  it "sends this machine's access token with web.public_url set (chi web asks it of loopback too)" do
    allow(Samagotchi::Web::Token).to receive(:read).and_return("T0KEN")
    allow(http).to receive(:get).and_return(reply)

    expect(described_class.call("127.0.0.1", 4567, timeout: 0.1)).to eq("app" => "chi-web")
    expect(http).to have_received(:get).with("/api/info", { "Authorization" => "Bearer T0KEN" })
  end

  context "without web.public_url" do
    let(:public_url) { nil }

    it "sends no token, even with a token file (the LAN's)" do
      allow(Samagotchi::Web::Token).to receive(:read).and_return("T0KEN")
      allow(http).to receive(:get).and_return(reply)

      described_class.call("127.0.0.1", 4567, timeout: 0.1)
      expect(http).to have_received(:get).with("/api/info", {})
    end
  end

  it "sends no Authorization without a token file" do
    allow(Samagotchi::Web::Token).to receive(:read).and_return(nil)
    allow(http).to receive(:get).and_return(reply)

    described_class.call("127.0.0.1", 4567, timeout: 0.1)
    expect(http).to have_received(:get).with("/api/info", {})
  end
end
