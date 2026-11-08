# frozen_string_literal: true

require "ipaddr"
require_relative "config"

module Samagotchi
  # What a host's address says about it, without asking it: whether it is
  # remote (a provider on the network rather than a local server), and the
  # configured first-token limit. A leaf: HostRegistry::HostEntry and
  # BootstrapCommand read it, it reads only Config.
  module HostAddress
    # Loopback, private (RFC 1918, IPv6 unique local) and link-local nets.
    LOCAL_NETS = %w[127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10
                    ::1/128 fc00::/7 fe80::/10].map { |net| IPAddr.new(net) }.freeze

    # Name suffixes that stay on a home or office network: mDNS, the
    # special-use and customary private names, router defaults (fritz.box)
    # and Tailscale's MagicDNS. Compared on whole labels.
    LOCAL_NAME_SUFFIXES = %w[localhost local lan home home.arpa internal intranet localdomain private corp test
                             box ts.net].freeze

    # Whether an address is remote: https, an http IP address outside the
    # local nets (LOCAL_NETS), or an http name with a dot whose suffix isn't
    # a local one (LOCAL_NAME_SUFFIXES): `gpu.example.com` is remote, while
    # `box`, `mac.local`, `gpu.lan` and `pc.tail1234.ts.net` are local. chi
    # doesn't look names up; hosts.<name>.remote overrides either way.
    def self.remote_address?(scheme, host)
      return true if scheme.to_s == "https"

      address = IPAddr.new(host.to_s.delete_prefix("[").delete_suffix("]"))
      address = address.native if address.ipv4_mapped?
      LOCAL_NETS.none? { |net| net.family == address.family && net.include?(address) }
    rescue IPAddr::Error
      remote_name?(host)
    end

    def self.remote_name?(host)
      name = host.to_s.downcase.delete_suffix(".")
      return false unless name.include?(".")

      LOCAL_NAME_SUFFIXES.none? { |suffix| name == suffix || name.end_with?(".#{suffix}") }
    end
    private_class_method :remote_name?

    # server.first_token_timeout, or nil when unset or unreadable.
    def self.configured_first_token_timeout
      Config.get("server.first_token_timeout")
    rescue StandardError # degrade-ok: no configured limit; the host's own or the remote default applies
      nil
    end
  end
end
