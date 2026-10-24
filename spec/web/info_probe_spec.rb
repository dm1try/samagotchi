# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/info_probe"
require "samagotchi/web/token"

RSpec.describe Samagotchi::Web::InfoProbe do
  let(:http) { double("http") }
  let(:reply) { double("reply", code: "200", body: '{"app":"chi-web"}') }

  before { allow(Net::HTTP).to receive(:start).and_yield(http) }

  # Whatever listens on the port may be another user's process on a shared
  # host: it never gets the token, with or without web.public_url.
  it "never sends a token, whatever the config and the token file" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("web.public_url").and_return("https://4567.pod.test")
    allow(Samagotchi::Web::Token).to receive(:read).and_return("T0KEN")
    allow(http).to receive(:get).and_return(reply)

    expect(described_class.call("127.0.0.1", 4567, timeout: 0.1)).to eq("app" => "chi-web")
    expect(http).to have_received(:get).with("/api/info")
  end
end
