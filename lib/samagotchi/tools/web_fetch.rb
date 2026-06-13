
# frozen_string_literal: true

require "net/http"
require "uri"
require "nokogiri"

module Samagotchi
  module Tools
    # Fetches the content of a URL and returns cleaned text content.
    class WebFetch
      NAME        = "web_fetch"
      DESCRIPTION = "Fetch the content of a URL (HTML or text) and return cleaned text. Handles HTML by stripping scripts/styles and extracting visible text. Returns error messages for invalid URLs or HTTP errors."
      TIMEOUT_SEC = 15
      MAX_OUTPUT_BYTES = 32 * 1024

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(url)
        url = url.to_s.strip
        return "Error: URL is required" if url.empty?

        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          return "Error: invalid URL scheme. Expected http:// or https://"
        end

        response = fetch_url(uri)
        return handle_http_error(response, uri) unless response.is_a?(Net::HTTPSuccess)

        content_type = response["content-type"] || ""
        return extract_text_from_html(response.body) if content_type.include?("text/html")
        return response.body if content_type.include?("text/")

        "Error: unsupported content type: #{content_type}"
      rescue URI::InvalidURIError
        "Error: invalid URI format"
      rescue SocketError
        "Error: could not resolve hostname"
      rescue Timeout::Error
        "Error: request timed out after #{TIMEOUT_SEC}s"
      rescue => e
        "Error: #{e.message}"
      end

      def self.fetch_url(uri)
        Net::HTTP.start(uri.host, uri.port,
                        use_ssl: uri.scheme == "https",
                        open_timeout: TIMEOUT_SEC,
                        read_timeout: TIMEOUT_SEC) do |http|
          request = Net::HTTP::Get.new(uri.request_uri)
          request["User-Agent"] = "Samagotchi/1.0 (AI Assistant)"
          http.request(request)
        end
      end

      def self.handle_http_error(response, uri)
        case response
        when Net::HTTPNotFound
          "Error: 404 Not Found for #{uri}"
        when Net::HTTPForbidden
          "Error: 403 Forbidden for #{uri}"
        when Net::HTTPUnauthorized
          "Error: 401 Unauthorized for #{uri}"
        when Net::HTTPGatewayTimeout, Net::HTTPBadGateway
          "Error: server error (#{response.code}) for #{uri}"
        else
          "Error: HTTP #{response.code} for #{uri}"
        end
      end

      def self.extract_text_from_html(html)
        return "Error: empty HTML response" if html.nil? || html.empty?

        doc = Nokogiri::HTML(html)

        # Remove script and style elements
        doc.css("script, style, noscript, iframe, svg").remove

        # Get text content
        text = doc.text
        text = text.gsub(/\s+/, " ").strip
        text = text.gsub(/\n\s*\n/, "\n\n").strip

        return "Error: no visible text content found in HTML" if text.empty?

        # Truncate to max output bytes
        if text.bytesize > MAX_OUTPUT_BYTES
          text = text.byteslice(0, MAX_OUTPUT_BYTES)
          text = "#{text}... [TRUNCATED - content too large]"
        end

        text
      end
    end
  end
end

