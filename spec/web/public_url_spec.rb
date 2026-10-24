# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/public_url"

RSpec.describe Samagotchi::Web::PublicUrl do
  def build(url, header: nil, owner: nil) = described_class.from_config(url: url, identity_header: header, owner: owner)

  it "is nil without a url" do
    expect(build(nil)).to be_nil
    expect(build("  ")).to be_nil
  end

  it "keeps an https origin, the port only when it isn't 443, lower-cased" do
    expect(build("https://Pod.Example.com").to_h).to include(origin: "https://pod.example.com", host: "pod.example.com")
    expect(build("https://pod.example.com:443/").host).to eq("pod.example.com")
    expect(build("https://4599.pod.example.com:8443").to_h)
      .to include(origin: "https://4599.pod.example.com:8443", host: "4599.pod.example.com:8443")
  end

  it "refuses anything but an https origin" do
    ["http://pod.example.com", "https://pod.example.com/chi", "https://pod.example.com/?a=1", "https://u:p@pod.example.com",
     "https://pod.example.com/#x", "pod.example.com", "https://", "https://exa mple.com"].each do |url|
      expect { build(url) }.to raise_error(described_class::Invalid, /must be an https origin/), url
    end
  end

  it "has no identity header unless one is named (none is unset), and checks the name" do
    expect(build("https://p.example").identity_header).to be_nil
    expect(build("https://p.example", header: "none").identity_env).to be_nil
    expect(build("https://p.example", header: "X-Forwarded-Email").identity_env).to eq("HTTP_X_FORWARDED_EMAIL")
    expect { build("https://p.example", header: "X_Forwarded_Email") }.to raise_error(described_class::Invalid, /header name/)
  end

  it "lower-cases the owner and refuses one without an identity header to check it against" do
    expect(build("https://p.example", header: "X-Forwarded-Email", owner: " Me@Corp.Example ").owner).to eq("me@corp.example")
    expect { build("https://p.example", owner: "me@corp.example") }
      .to raise_error(described_class::Invalid, /needs web.proxy.identity_header/)
  end

  it "puts the token in the link's fragment" do
    public_url = build("https://p.example")
    expect(public_url.link("T")).to eq("https://p.example/#token=T")
    expect(public_url.link("chp_x", "s=abc")).to eq("https://p.example/#token=chp_x&s=abc")
  end
end
