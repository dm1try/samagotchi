# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "openssl"
require_relative "../session_access"

module Samagotchi
  module SessionAccess
    # A remote's chi web over HTTP (Net::HTTP), its access token as
    # Authorization: Bearer: one request per call, each on its own
    # connection (a command makes a handful). A connection that fails
    # raises RemoteFailed naming the remote and why.
    class HTTPTransport
      # One answer: the status, the body, and the body read as JSON (nil
      # when it isn't).
      Reply = Data.define(:status, :body, :json) do
        def self.of(status, body)
          json = begin
            JSON.parse(body.to_s)
          rescue JSON::ParserError
            nil
          end
          new(status: status.to_i, body: body.to_s, json: json)
        end

        def error = json.is_a?(Hash) ? json["error"] : nil
      end

      OPEN_TIMEOUT = 5
      # Above chi web's longest answer (a wait route's 30 s, a create's
      # wait for its worker).
      READ_TIMEOUT = 75

      # @param entry [Remotes::Entry]
      def initialize(entry, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
        @entry = entry
        @uri = URI(entry.url)
        @open_timeout = open_timeout
        @read_timeout = read_timeout
      end

      def inspect = "#<#{self.class.name} #{@entry.label}>"

      # @param method [Symbol] :get, :post, :delete
      # @param path [String] "/api/…"
      # @param query [Hash, nil] the query's parameters (nil values left out)
      # @param body [Hash, nil] sent as JSON
      # @param raw [String, nil] sent as is (an image), with +content_type+
      # @param read_timeout [Numeric, nil] this request's, instead of the
      #   transport's (a remote attach's turn, its join reads)
      # @return [Reply]
      # @raise [RemoteFailed] it could not be asked
      def call(method, path, query: nil, body: nil, raw: nil, content_type: nil, read_timeout: nil)
        read_timeout ||= @read_timeout
        request = build(method, path, query)
        request["Authorization"] = "Bearer #{@entry.token}" if @entry.token
        request["Accept"] = "application/json"
        if raw
          request["Content-Type"] = content_type || "application/octet-stream"
          request.body = raw
        elsif body
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(body)
        elsif method != :get
          request["Content-Length"] = "0"
        end
        response = http(read_timeout).request(request)
        Reply.of(response.code, response.body)
      rescue Errno::ECONNREFUSED
        failed("connection refused")
      rescue Net::OpenTimeout, Errno::ETIMEDOUT
        failed("no answer within #{@open_timeout} s")
      rescue Net::ReadTimeout
        failed("it took the request but sent no answer within #{read_timeout} s")
      rescue SocketError => e
        failed(e.message.include?("getaddrinfo") ? "can't find host #{@uri.host}" : e.message)
      rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH
        failed("host unreachable")
      rescue OpenSSL::SSL::SSLError => e
        failed("TLS failed: #{e.message}")
      rescue IOError, SystemCallError => e
        failed("the connection broke (#{e.class.name.split("::").last})")
      end

      private

      def http(read_timeout)
        Net::HTTP.new(@uri.host, @uri.port).tap do |http|
          http.use_ssl = @uri.scheme == "https"
          http.open_timeout = @open_timeout
          http.read_timeout = read_timeout
          http.write_timeout = read_timeout
          http.max_retries = 0
        end
      end

      def build(method, path, query)
        target = path
        params = query&.compact
        target = "#{path}?#{URI.encode_www_form(params)}" if params && !params.empty?
        { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(target)
      end

      def failed(reason) = raise(RemoteFailed, "#{@entry.label}: #{reason}")
    end
  end
end
