# frozen_string_literal: true

require "net/http"
require "openssl"
require "zlib"
require_relative "http"
require_relative "../llm/http"
require_relative "../llm/errors"

module Samagotchi
  module Plugin
    class Http
      # Plugin::Http's wire: one LLM::HTTP request per call (chi's TLS,
      # proxies, User-Agent, cancel by closing the socket, and one log line
      # without query, headers or body), with chi's retries off. Every
      # network, TLS, protocol or provider error but a cancel becomes an
      # HttpError, so a plugin rescues one type; anything else is a bug in
      # chi, logged with its backtrace and raised as it is.
      #
      # Loaded with the first real request (it pulls in net/http and the
      # LLM layer). Stateless.
      class NetTransport
        # What went wrong, in words (a message never carries a response).
        REASONS = {
          Errno::ECONNREFUSED => "connection refused", Errno::ECONNRESET => "connection reset",
          Errno::EHOSTUNREACH => "host unreachable", Errno::ENETUNREACH => "network unreachable",
          Errno::ETIMEDOUT => "timed out", Errno::EPIPE => "connection closed",
          Timeout::Error => "timed out", IO::TimeoutError => "timed out", EOFError => "connection closed",
          SocketError => "can't resolve the host", OpenSSL::SSL::SSLError => "TLS error",
          Net::HTTPBadResponse => "malformed response", Net::HTTPHeaderSyntaxError => "malformed response",
          Net::ProtocolError => "protocol error", Zlib::Error => "bad compressed body"
        }.freeze

        # The errors a request's wire may raise: each becomes an HttpError.
        WIRE_ERRORS = [
          *REASONS.keys, *LLM::HTTP::NETWORK_ERRORS, SystemCallError, IOError, OpenSSL::OpenSSLError,
          LLM::ProviderError
        ].uniq.freeze

        def initialize(bundle:)
          @bundle = bundle.to_s
        end

        # @return [Response]
        # @raise [HttpError, HttpCancelled]
        def call(method:, uri:, headers:, body:, timeout:, cancel:)
          request = Net::HTTP.const_get(method.capitalize).new(uri, headers)
          request.body = body if body
          client = LLM::HTTP.new(label: "plugin:#{@bundle}", open_timeout: timeout, read_timeout: timeout,
                                 retry_policy: LLM::HTTP::RetryPolicy.none)
          response = client.fetch(uri, request, retries: false, check_status: false, write_timeout: timeout, cancel_controller: cancel,
                                                log_fields: { purpose: "plugin", bundle: @bundle })
          build_response(response)
        rescue LLM::RequestCancelled
          raise HttpCancelled, "#{method} #{where(uri)}: cancelled"
        rescue HttpError
          raise
        rescue *WIRE_ERRORS => e
          raise HttpError, "#{method} #{where(uri)}: #{reason(e)}"
        rescue StandardError => e
          Log.exception(:plugins, "http_transport_failed", e, bundle: @bundle)
          raise
        end

        private

        def build_response(response)
          headers = {}
          response.each_header { |name, value| headers[name.downcase] = text(value) }
          Response.new(status: response.code.to_i, headers: headers.freeze, body: text(response.body))
        end

        # The bytes as UTF-8 when they are, else as they came.
        def text(body)
          text = body.to_s.dup
          utf8 = text.dup.force_encoding(Encoding::UTF_8)
          utf8.valid_encoding? ? utf8 : text.force_encoding(Encoding::BINARY)
        end

        def where(uri) = "#{uri.host}:#{uri.port}"

        def reason(error)
          REASONS.find { |klass, _| error.is_a?(klass) }&.last || "failed (#{error.class.name})"
        end
      end
    end
  end
end
