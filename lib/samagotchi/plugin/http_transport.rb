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
        rescue StandardError => e
          raise mapped(e, method, uri)
        end

        # One streamed attempt (Plugin::Http#stream): the block gets a Stream
        # whose reads map a wire error (or a cancel's closed socket) as
        # #call does. Only chi's own code between the request and the block
        # is under the catch-all: what the block raises goes on as it is.
        # @return [Object] the block's value
        # @raise [HttpError, HttpCancelled]
        def stream(method:, uri:, headers:, body:, timeout:, cancel:)
          request = Net::HTTP.const_get(method.capitalize).new(uri, headers)
          request.body = body if body
          client = LLM::HTTP.new(label: "plugin:#{@bundle}", open_timeout: timeout, read_timeout: timeout,
                                 retry_policy: LLM::HTTP::RetryPolicy.none)
          raised = nil
          client.open_stream(uri, request, write_timeout: timeout, cancel_controller: cancel,
                                           log_fields: { purpose: "plugin", bundle: @bundle }) do |response, marks|
            stream = Stream.new(status: response.code.to_i, headers: headers_of(response),
                                reader: ->(&on_chunk) { response.read_body(&on_chunk) },
                                failure: ->(error) { read_failure(error, marks, cancel, method, uri) })
            yield stream
          rescue StandardError => e
            raised = e
            raise
          end
        rescue StandardError => e
          raise if e.equal?(raised)

          raise mapped(e, method, uri)
        end

        private

        # A request's error as the plugin sees it: a cancel, a wire error
        # (HttpError), or chi's own bug, logged and raised as it is.
        def mapped(error, method, uri)
          case error
          when LLM::RequestCancelled then HttpCancelled.new("#{method} #{where(uri)}: cancelled")
          when HttpError then error
          when *WIRE_ERRORS then HttpError.new("#{method} #{where(uri)}: #{reason(error)}")
          else
            Log.exception(:plugins, "http_transport_failed", error, bundle: @bundle)
            error
          end
        end

        # A Stream read that failed: the cancel's closed socket, else a wire
        # error, marked for the log line (LLM::HTTP::StreamMarks).
        def read_failure(error, marks, cancel, method, uri)
          if cancel&.cancelled?
            marks.cancelled(cancel.reason)
            return HttpCancelled.new("#{method} #{where(uri)}: cancelled")
          end
          marks.failed(error)
          mapped(error, method, uri)
        end

        def build_response(response)
          Response.new(status: response.code.to_i, headers: headers_of(response), body: Http.text(response.body))
        end

        def headers_of(response)
          headers = {}
          response.each_header { |name, value| headers[name.downcase] = Http.text(value) }
          headers.freeze
        end

        def where(uri) = "#{uri.host}:#{uri.port}"

        def reason(error)
          REASONS.find { |klass, _| error.is_a?(klass) }&.last || "failed (#{error.class.name})"
        end
      end
    end
  end
end
