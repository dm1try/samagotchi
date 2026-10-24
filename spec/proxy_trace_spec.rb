# frozen_string_literal: true

require "spec_helper"
require "samagotchi/proxy_trace"

RSpec.describe Samagotchi::ProxyTrace do
  it "knows the headers proxies add, by prefix and by name, in any case and with underscores" do
    %w[X-Forwarded-For x-forwarded-host X_Forwarded_Proto X-Forwarded-Email Forwarded X-Real-IP Via True-Client-IP
       X-Auth-Request-Email x_auth_request_user Cf-Connecting-Ip Cf-Access-Jwt-Assertion Tailscale-User-Login
       X-Authentik-Email Remote-User Remote-Email X-Original-URL].each do |name|
      expect(described_class.header?(name)).to be(true), name
    end
  end

  it "leaves chi's own clients' headers alone" do
    %w[Host Content-Type Content-Length Authorization Last-Event-ID Accept Cookie Connection User-Agent Origin].each do |name|
      expect(described_class.header?(name)).to be(false), name
    end
  end

  it "reads a header's name from a Rack env key" do
    expect(described_class.env_name("HTTP_X_FORWARDED_FOR")).to eq("x-forwarded-for")
    expect(described_class.env_name("REMOTE_ADDR")).to be_nil
  end
end
