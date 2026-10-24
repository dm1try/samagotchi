# frozen_string_literal: true

require "json"
require "net/http"
require_relative "token"
require_relative "../config"

module Samagotchi
  module Web
    # What answers GET /api/info on host:port: the one probe for a running
    # chi web (chi web's own port check, chi share's link, chi update, chi
    # self). With web.public_url set chi web asks this machine for its access
    # token too, so then it sends web-token's; otherwise none (whatever
    # listens on the port gets no token it doesn't need).
    module InfoProbe
      module_function

      # @param token [String, nil] the access token to send (Bearer);
      #   default: web-token's with web.public_url set, else none
      # @return [Hash, :free, :other] a chi web's /api/info; :free when
      #   nothing listens; :other for anything else (another program, an
      #   error status, a body that isn't a chi web's)
      def call(host, port, timeout:, token: owner_token)
        headers = token ? { "Authorization" => "Bearer #{token}" } : {}
        response = Net::HTTP.start(host, port, open_timeout: timeout, read_timeout: timeout) do |http|
          http.get("/api/info", headers)
        end
        verdict(response.code.to_i, response.body)
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        :free
      rescue StandardError
        :other
      end

      def owner_token
        Samagotchi::Config.get("web.public_url").to_s.strip.empty? ? nil : Token.read
      end

      def verdict(status, body)
        info = status == 200 ? JSON.parse(body.to_s) : nil
        info.is_a?(Hash) && info["app"] == "chi-web" ? info : :other
      rescue JSON::ParserError
        :other
      end
    end
  end
end
