# frozen_string_literal: true

require "json"
require "uri"
require_relative "http_errors"

module Samagotchi
  module Plugin
    # An HTTP client for a plugin (ctx.http, docs/plugins.md): a few methods,
    # a small Response, one error type (HttpError). It checks its arguments
    # and builds the request; a transport (Http::NetTransport by default,
    # the test kit's FakeHttp) puts it on the wire.
    #
    # Stateless apart from its bundle's name and its transport: any number of
    # threads may call it.
    #
    # This file needs only json and uri: net/http and chi's HTTP layer load
    # with the first real request (NetTransport).
    class Http
      # What a request is given as the timeout (open, and per read) when none is.
      DEFAULT_TIMEOUT = 10
      METHODS = %w[GET POST PUT PATCH DELETE HEAD].freeze

      # One answer. +headers+ is frozen, with lower-case names and a repeated
      # header's values joined with ", "; +body+ is never nil (HEAD and empty
      # bodies are ""), tagged UTF-8 when its bytes are valid UTF-8, else
      # left binary (scrub it before handing unknown text to the model).
      Response = Data.define(:status, :headers, :body) do
        # @return [Boolean] a 2xx status
        def ok? = status.between?(200, 299)

        # The body parsed as JSON, on each call (a Data keeps nothing).
        # @raise [HttpError] the body isn't JSON
        def json
          JSON.parse(body)
        rescue JSON::ParserError, EncodingError
          raise HttpError, "not JSON: status #{status}, #{body.bytesize} bytes"
        end
      end

      # @param bundle [String] the bundle's name (the log line's bundle=)
      # @param cancel_lookup [#call] → the CancellationController a call
      #   without cancel: uses (nil: none), read at call time
      # @param transport [#call, nil] call(method:, uri:, headers:, body:,
      #   timeout:, cancel:) → Response, or raises HttpError / HttpCancelled;
      #   stream(same keywords) { |stream| … } → the block's value
      def initialize(bundle:, cancel_lookup: -> {}, transport: nil)
        @bundle = bundle.to_s
        @cancel_lookup = cancel_lookup
        @transport = transport
      end

      # @param url [String, URI] http or https
      # @param headers [Hash] header name => value
      # @param timeout [Numeric] seconds: open, and each read
      # @param cancel [CancellationController, nil] overrides the default
      #   (the turn's, for a call made for the turn)
      # @return [Response] any status: a 4xx/5xx is returned, not raised
      # @raise [ArgumentError] a bad URL, scheme, header or timeout
      # @raise [HttpError] the request didn't complete
      # @raise [HttpCancelled] it was cancelled
      def get(url, headers: {}, timeout: DEFAULT_TIMEOUT, cancel: nil)
        request("GET", url, headers: headers, timeout: timeout, cancel: cancel)
      end

      # POST +body+ encoded as JSON (Content-Type and Accept: application/json
      # unless +headers+ name them).
      # @param body [Object] anything JSON can encode
      # @raise [ArgumentError] +body+ can't be encoded as JSON, and as #get
      def post_json(url, body, headers: {}, timeout: DEFAULT_TIMEOUT, cancel: nil)
        encoded = begin
          JSON.generate(body)
        rescue JSON::JSONError, EncodingError => e
          raise ArgumentError, "can't encode the body as JSON: #{e.class}"
        end
        headers = { "Content-Type" => "application/json", "Accept" => "application/json" }
                  .reject { |name, _| named?(headers, name) }.merge(headers)
        request("POST", url, body: encoded, headers: headers, timeout: timeout, cancel: cancel)
      end

      # @param method [String, Symbol] GET POST PUT PATCH DELETE HEAD
      # @param body [String, nil] sent as is (set your own Content-Type)
      # @raise [ArgumentError] an unknown method, a body that isn't a String, and as #get
      def request(method, url, body: nil, headers: {}, timeout: DEFAULT_TIMEOUT, cancel: nil)
        transport.call(**wire_args(method, url, body, headers, timeout, cancel))
      end

      # A streamed request: the block gets a Stream (status and headers
      # first, then the body as it arrives: Stream#each_event,
      # #each_chunk, #body). Leaving the block closes the connection,
      # however it is left (its end, break, return, a raise; the raise goes
      # on as it is). Arguments, checks, cancel, proxies, User-Agent and
      # the log line as #request; no retries; +timeout+ is the connect, the
      # write and each read, not a total deadline.
      # @yield [Stream]
      # @return [Object] the block's value
      # @raise [ArgumentError] no block, and as #request
      # @raise [HttpError, HttpCancelled] before the block, or from a
      #   Stream read inside it
      def stream(method, url, body: nil, headers: {}, timeout: DEFAULT_TIMEOUT, cancel: nil, &block)
        raise ArgumentError, "ctx.http.stream needs a block (it gets the Stream)" unless block

        transport.stream(**wire_args(method, url, body, headers, timeout, cancel), &block)
      end

      # +bytes+ tagged UTF-8 when they are valid UTF-8, else binary.
      def self.text(bytes)
        text = bytes.to_s.dup
        utf8 = text.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : text.force_encoding(Encoding::BINARY)
      end

      private

      # The checked arguments a transport gets.
      def wire_args(method, url, body, headers, timeout, cancel)
        verb = method.to_s.upcase
        raise ArgumentError, "unknown HTTP method #{method.inspect} (#{METHODS.join(", ")})" unless METHODS.include?(verb)
        raise ArgumentError, "the body must be a String (or nil), got #{body.class}" unless body.nil? || body.is_a?(String)

        { method: verb, uri: parse_url(url), headers: header_hash(headers), body: body,
          timeout: timeout_seconds(timeout), cancel: cancel || @cancel_lookup.call }
      end

      def transport
        @transport ||= begin
          require_relative "http_transport"
          NetTransport.new(bundle: @bundle)
        end
      end

      def parse_url(url)
        uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
        unless uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
          raise ArgumentError, "the URL must be http:// or https:// with a host: #{quotable(url)}"
        end

        uri
      rescue URI::InvalidURIError
        raise ArgumentError, "not a URL: #{quotable(url)}"
      end

      # +url+ as an error message may quote it: its first 100 characters
      # without the query, fragment and user info (a key in them would reach
      # the logs with the message).
      def quotable(url)
        text = url.to_s.sub(/[?#].*\z/m, "").sub(%r{\A([a-z][a-z0-9+.-]*://)[^/@]*@}i, "\\1")
        text[0, 100].inspect
      end

      def header_hash(headers)
        raise ArgumentError, "headers must be a Hash" unless headers.is_a?(Hash)

        headers.to_h do |name, value|
          name = name.to_s
          value = value.to_s
          unless name.match?(/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/) && !value.match?(/[\r\n\0]/)
            raise ArgumentError, "bad header #{name[0, 40].inspect}: a name of token characters, a value on one line"
          end

          [name, value]
        end
      end

      def named?(headers, name)
        headers.keys.any? { |key| key.to_s.casecmp?(name) }
      end

      def timeout_seconds(timeout)
        raise ArgumentError, "timeout must be a positive number of seconds" unless timeout.is_a?(Numeric) && timeout.positive?

        timeout.to_f
      end
    end
  end
end

# After Http: its Stream and SseReader reopen the class.
require_relative "http_stream"
