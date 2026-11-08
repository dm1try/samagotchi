# frozen_string_literal: true

require "samagotchi/host_address"

RSpec.describe Samagotchi::HostAddress do
  describe ".remote_address?" do
    it "is https, an IP outside the local nets, or a dotted name without a local suffix" do
      expect(described_class.remote_address?("https", "192.168.1.5")).to be(true)
      expect(described_class.remote_address?("http", "203.0.113.7")).to be(true)
      expect(described_class.remote_address?("http", "gpu.example.com")).to be(true)
    end

    it "is false for the local nets (IPv4-mapped too) and the local names" do
      %w[127.0.0.1 10.1.2.3 192.168.1.29 100.101.102.103 ::1 [fe80::1] ::ffff:192.168.0.2 box mac.local gpu.lan
         pc.tail1234.ts.net fritz.box localhost].each do |host|
        expect(described_class.remote_address?("http", host)).to be(false), host
      end
    end
  end

  describe ".configured_first_token_timeout" do
    it "is server.first_token_timeout, nil when it can't be read" do
      allow(Samagotchi::Config).to receive(:get).with("server.first_token_timeout").and_return(30)
      expect(described_class.configured_first_token_timeout).to eq(30)

      allow(Samagotchi::Config).to receive(:get).with("server.first_token_timeout").and_raise(IOError)
      expect(described_class.configured_first_token_timeout).to be_nil
    end
  end
end
