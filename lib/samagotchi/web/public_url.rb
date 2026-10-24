# frozen_string_literal: true

require "uri"
require_relative "../redacted_inspect"

module Samagotchi
  module Web
    # chi web behind an auth proxy (web.public_url, docs/configuration.md
    # "Behind an auth proxy"): the https origin people open, the request
    # header the proxy puts the signed-in user's email in (nil: none is
    # trusted, the chi token alone decides) and the owner's email. Set, it
    # turns on proxied mode (Web::ProxyGate): every request needs a token.
    PublicUrl = Data.define(:origin, :host, :identity_header, :owner) do
      # The Rack env key of the identity header (HTTP_X_FORWARDED_EMAIL),
      # nil without one.
      def identity_env = identity_header && PublicUrl.env_key(identity_header)

      # The header's name as people write it, or "none".
      def identity_label = identity_header || "none"

      # https://host[:port]/#token=TOKEN: the owner's link (the token rides
      # in the fragment, which no proxy or IdP sees).
      def link(token, fragment = nil) = "#{origin}/##{["token=#{token}", fragment].compact.join("&")}"
    end

    class PublicUrl
      class Invalid < StandardError; end

      # An HTTP header name (RFC 9110 token characters chi accepts).
      HEADER_NAME = /\A[A-Za-z0-9][A-Za-z0-9-]*\z/

      # @return [PublicUrl, nil] nil when +url+ is unset
      # @raise [Invalid] a url that isn't an https origin, a bad header name,
      #   or an owner without an identity header to check it against
      def self.from_config(url:, identity_header: nil, owner: nil)
        text = url.to_s.strip
        return nil if text.empty?

        origin, host = parse_origin(text)
        header = identity_header.to_s.strip
        header = nil if header.empty? || header.casecmp?("none")
        if header && !HEADER_NAME.match?(header)
          raise Invalid, "web.proxy.identity_header must be a header name (letters, digits and -), not #{header}"
        end

        owner = owner.to_s.strip.downcase
        owner = nil if owner.empty?
        if owner && header.nil?
          raise Invalid, "web.proxy.owner needs web.proxy.identity_header (the header the proxy puts #{owner} in); " \
                         "without one only the chi token decides, so leave owner unset"
        end

        new(origin: origin, host: host, identity_header: header, owner: owner)
      end

      def self.parse_origin(text)
        uri = URI.parse(text)
        bare = uri.path.to_s.empty? || uri.path == "/"
        unless uri.scheme&.downcase == "https" && uri.host && !uri.host.empty? && bare && uri.query.nil? &&
               uri.fragment.nil? && uri.userinfo.nil?
          raise Invalid, invalid_url(text)
        end

        name = uri.host.downcase
        host = uri.port == 443 ? name : "#{name}:#{uri.port}"
        ["https://#{host}", host]
      rescue URI::InvalidURIError
        raise Invalid, invalid_url(text)
      end

      def self.invalid_url(text) = "web.public_url must be an https origin (https://host or https://host:port), not #{text}"

      # The Rack env key WEBrick makes of a header name.
      def self.env_key(name) = "HTTP_#{name.upcase.tr("-", "_")}"
    end
  end
end
