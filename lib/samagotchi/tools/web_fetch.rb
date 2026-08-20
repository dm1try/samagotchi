
# frozen_string_literal: true

require "net/http"
require "uri"
require "ipaddr"
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

        return "Error: SSRF protection blocked access to internal/private host" unless ssrf_protected?(uri)

        response = fetch_url(uri)
        return handle_http_error(response, uri) unless response.is_a?(Net::HTTPSuccess)

        content_type = response["content-type"] || ""
        return to_utf8(extract_text_from_html(response.body)) if content_type.include?("text/html")
        return to_utf8(response.body) if content_type.include?("text/")

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

      def self.ssrf_protected?(uri)
        return true if uri.host.nil?

        private_ranges = [
          IPAddr.new("127.0.0.0/8"),
          IPAddr.new("10.0.0.0/8"),
          IPAddr.new("172.16.0.0/12"),
          IPAddr.new("192.168.0.0/16"),
          IPAddr.new("169.254.0.0/16"),
          IPAddr.new("0.0.0.0/8"),
          IPAddr.new("::1/128"),
          IPAddr.new("fc00::/7"),
          IPAddr.new("fe80::/10"),
          IPAddr.new("::ffff:0:0/96"),
        ]

        # Try to parse host as IP directly
        begin
          ip = IPAddr.new(uri.host)
          private_ranges.each { |range| return false if range.include?(ip) }
          return true
        rescue IPAddr::InvalidAddressError
          # Host is a domain name — resolve and check
        end

        # Resolve domain to IP and check
        begin
          addr_info = Socket.getaddrinfo(uri.host, 80, :INET, :STREAM)
          ip = addr_info.first[3]
          private_ranges.each { |range| return false if range.include?(ip) }
        rescue SocketError
          # DNS failure — let fetch URL handle it
        end

        true
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

      # Network bodies come back tagged ASCII-8BIT even when they hold UTF-8
      # bytes (web text is essentially always UTF-8). Relabel as UTF-8 so the
      # result can be safely interpolated into UTF-8 strings (logs, conversation
      # history) without raising
      # "incompatible character encodings: UTF-8 and BINARY (ASCII-8BIT)".
      # Falls back to lossy replacement only if the bytes are genuinely not
      # valid UTF-8.
      def self.to_utf8(str)
        s = str.to_s
        return s if s.encoding == Encoding::UTF_8 && s.valid_encoding?

        s = s.dup.force_encoding(Encoding::UTF_8)
        return s if s.valid_encoding?

        s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      end

      def self.extract_text_from_html(html)
        return "Error: empty HTML response" if html.nil? || html.empty?

        doc = Nokogiri::HTML(html)

        # Extract noscript text before removing it
        doc.css("noscript").each do |node|
          node.replace(node.text) if node.text?
        end

        # Remove script, style, iframe, svg elements
        doc.css("script, style, iframe, svg").remove

        # Get text content
        text = doc.text
        text = text.gsub(/\s+/, " ").strip
        text = text.gsub(/\n\s*\n/, "\n\n").strip

        return "Error: no visible text content found in HTML" if text.empty?

        # Truncate to max output bytes
        if text.bytesize > MAX_OUTPUT_BYTES
          suffix = "... [TRUNCATED - content too large]"
          budget = MAX_OUTPUT_BYTES - suffix.bytesize
          truncated = text.byteslice(0, budget)
          truncated = truncated.encode("UTF-8", invalid: :replace, undef: :replace)
          text = "#{truncated}#{suffix}"
        end

        text
      end
    end
  end
end

