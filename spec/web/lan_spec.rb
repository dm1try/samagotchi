# frozen_string_literal: true

require "spec_helper"
require "socket"

require "samagotchi/web/lan"

RSpec.describe Samagotchi::Web::Lan do
  let(:ifaddr) { Struct.new(:name, :addr, :flags) }

  def iface(name, ip, up: true, loopback: false)
    flags = (up ? Socket::IFF_UP : 0) | (loopback ? Socket::IFF_LOOPBACK : 0)
    ifaddr.new(name, ip && Addrinfo.ip(ip), flags)
  end

  let(:machine) do
    [
      iface("lo0", "127.0.0.1", loopback: true),
      iface("lo0", "::1", loopback: true),
      iface("utun4", "10.8.0.2"),
      iface("bridge100", "192.168.64.1"),
      iface("en7", "10.0.0.3", up: false),
      iface("en0", "fe80::1"),
      iface("en0", nil),
      iface("en0", "192.168.1.55"),
      iface("docker0", "172.17.0.1"),
      iface("vboxnet0", "192.168.56.1"),
      iface("vmnet8", "172.16.9.1"),
      iface("llw0", "10.9.9.9"),
      iface("en5", "10.0.0.4"),
      iface("utun7", "100.101.102.103")
    ]
  end

  describe ".wanted?" do
    it "is lan or an IPv4 address that isn't loopback or 0.0.0.0" do
      expect(%w[lan 192.168.1.55 100.101.102.103 8.8.8.8].map { |h| described_class.wanted?(h) }).to all(be true)
      expect(["127.0.0.1", "127.0.0.2", "::1", "localhost", "0.0.0.0", "", "LAN", "mac.local", "fe80::1", "999.1.1.1",
              nil].map { |h| described_class.wanted?(h) }).to all(be false)
    end
  end

  describe ".choose" do
    it "picks lan's address among private IPv4s on interfaces that are up, skipping tunnels, bridges, VMs and containers" do
      choice = described_class.choose("lan", ifaddrs: machine)

      expect([choice.ip, choice.interface, choice.public]).to eq(["192.168.1.55", "en0", false])
      expect(choice.others.map(&:to_s)).to eq(["10.0.0.4 (en5)"])
    end

    it "takes the first in the system's order" do
      choice = described_class.choose("lan", ifaddrs: [iface("en5", "10.0.0.4"), iface("en0", "192.168.1.55")])
      expect(choice.ip).to eq("10.0.0.4")
    end

    it "refuses lan when there is no private address" do
      expect { described_class.choose("lan", ifaddrs: machine.first(4)) }
        .to raise_error(described_class::Error, /no private IPv4 address/)
    end

    it "takes an explicit address of this machine, even on a skipped interface, and marks a non-private one" do
      expect(described_class.choose("10.0.0.4", ifaddrs: machine).to_h.slice(:ip, :interface, :public))
        .to eq(ip: "10.0.0.4", interface: "en5", public: false)
      tailscale = described_class.choose("100.101.102.103", ifaddrs: machine)
      expect([tailscale.interface, tailscale.public]).to eq(["utun7", true])
    end

    it "refuses an address that isn't this machine's, or whose interface is down" do
      expect { described_class.choose("192.168.1.99", ifaddrs: machine) }
        .to raise_error(described_class::Error, "web.host is 192.168.1.99, which isn't an address of this machine")
      expect { described_class.choose("10.0.0.3", ifaddrs: machine) }.to raise_error(described_class::Error)
    end
  end

  describe ".local_host" do
    it "is 127.0.0.1 for lan, a LAN address and anything unknown; ::1 and localhost as they are" do
      expect(%w[lan 192.168.1.55 127.0.0.1 0.0.0.0 bogus].map { |h| described_class.local_host(h) }).to all(eq("127.0.0.1"))
      expect(described_class.local_host(nil)).to eq("127.0.0.1")
      expect(described_class.local_host("::1")).to eq("::1")
      expect(described_class.local_host("localhost")).to eq("localhost")
    end
  end
end
