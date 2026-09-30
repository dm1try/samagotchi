# frozen_string_literal: true

require "json"
require "net/http"

module Samagotchi
  module Web
    # What answers GET /api/info on host:port: the one probe for a running
    # chi web (chi web's own port check, chi update, chi self).
    module InfoProbe
      module_function

      # @return [Hash, :free, :other] a chi web's /api/info; :free when
      #   nothing listens; :other for anything else (another program, an
      #   error status, a body that isn't a chi web's)
      def call(host, port, timeout:)
        response = Net::HTTP.start(host, port, open_timeout: timeout, read_timeout: timeout) { |http| http.get("/api/info") }
        verdict(response.code.to_i, response.body)
      rescue Errno::ECONNREFUSED, Errno::EADDRNOTAVAIL
        :free
      rescue StandardError
        :other
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
