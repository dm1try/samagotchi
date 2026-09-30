# frozen_string_literal: true

require "ipaddr"
require "socket"

module Samagotchi
  module Web
    # web.host beyond loopback: `lan` (this machine's private IPv4 address)
    # or one of its IPv4 addresses. chi web then listens on 127.0.0.1 and
    # that address; the local tools (a second chi web, chi update) keep
    # talking to 127.0.0.1 (local_host). IPv6 LAN addresses aren't offered.
    module Lan
      LOOPBACK_NAMES = %w[127.0.0.1 ::1 localhost].freeze
      # Interfaces `lan` never picks: VPN tunnels, bridges, VMs and
      # containers, Apple's low-latency link.
      SKIPPED = /\A(utun|bridge|docker|vboxnet|vmnet|llw)/
      PRIVATE = [IPAddr.new("10.0.0.0/8"), IPAddr.new("172.16.0.0/12"), IPAddr.new("192.168.0.0/16")].freeze

      Address = Struct.new(:ip, :interface, keyword_init: true) do
        def to_s = "#{ip} (#{interface})"
      end

      # The address chi web adds, the other private ones `lan` could have
      # picked (said in the startup lines), and whether it isn't a private
      # one (an explicit Tailscale or public address: a warning).
      Choice = Struct.new(:ip, :interface, :others, :public, keyword_init: true)

      class Error < StandardError; end

      module_function

      # Does this web.host ask for LAN access? `lan`, or an IPv4 address
      # that isn't loopback or 0.0.0.0 (never bound: every interface).
      def wanted?(setting)
        setting = setting.to_s.strip
        return true if setting == "lan"

        ip = ipv4(setting)
        !ip.nil? && !ip.loopback? && ip != IPAddr.new("0.0.0.0")
      end

      # Where this machine reaches its own chi web: the loopback address
      # for `lan` or a LAN address, ::1 and localhost as they are, and
      # 127.0.0.1 for anything else (chi web binds that instead).
      def local_host(setting)
        setting = setting.to_s.strip
        %w[::1 localhost].include?(setting) ? setting : "127.0.0.1"
      end

      # @param ifaddrs [Array<Socket::Ifaddr>] this machine's interfaces
      # @return [Choice]
      # @raise [Error] `lan` with no private address, or an address that
      #   isn't this machine's
      def choose(setting, ifaddrs: Socket.getifaddrs)
        setting = setting.to_s.strip
        mine = addresses(ifaddrs)
        if setting == "lan"
          candidates = mine.select { |a| private?(a.ip) && !a.interface.match?(SKIPPED) }
          raise Error, "web.host is lan, but this machine has no private IPv4 address on the network (Wi-Fi off?)" if candidates.empty?

          first, *others = candidates
          return Choice.new(ip: first.ip, interface: first.interface, others: others, public: false)
        end

        found = mine.find { |a| a.ip == setting }
        raise Error, "web.host is #{setting}, which isn't an address of this machine" unless found

        others = mine.select { |a| a.ip != found.ip && private?(a.ip) && !a.interface.match?(SKIPPED) }
        Choice.new(ip: found.ip, interface: found.interface, others: others, public: !private?(found.ip))
      end

      # This machine's IPv4 addresses on interfaces that are up, loopback
      # left out, in the system's order.
      def addresses(ifaddrs)
        ifaddrs.filter_map do |ifa|
          addr = ifa.addr
          next unless addr&.ipv4?
          next if ifa.flags.nobits?(Socket::IFF_UP) || ifa.flags.anybits?(Socket::IFF_LOOPBACK)

          Address.new(ip: addr.ip_address, interface: ifa.name)
        end.uniq(&:ip)
      end

      def private?(ip)
        addr = ipv4(ip)
        !addr.nil? && PRIVATE.any? { |net| net.include?(addr) }
      end

      def ipv4(text)
        return nil unless text.to_s.match?(/\A\d{1,3}(\.\d{1,3}){3}\z/)

        addr = IPAddr.new(text)
        addr.ipv4? ? addr : nil
      rescue IPAddr::Error
        nil
      end
    end
  end
end
