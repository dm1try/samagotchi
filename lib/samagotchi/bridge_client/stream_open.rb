# frozen_string_literal: true

require "json"
require_relative "../bridge_secret"

module Samagotchi
  class BridgeClient
    # The result of opening an SSE connection. Only Opened owns a socket the
    # caller may read; refused sockets are consumed for their detail and closed.
    module StreamOpen
      Opened = Data.define(:sock, :status, :headers)
      Refused = Data.define(:reason, :detail, :status)
      Unreachable = Data.define(:attempts, :detail) do
        def initialize(attempts:, detail: nil) = super
      end

      BODY_LIMIT = 16_384
      BODY_TIMEOUT = 5.0

      module_function

      # The one place a stream's response status is interpreted. Through chi
      # web, its mapped bridge-secret and not-live responses have their own
      # status codes (502 and 503).
      def classify(sock, status, headers)
        return Unreachable.new(attempts: 0) unless sock
        return Opened.new(sock: sock, status: 200, headers: headers) if status.to_i == 200

        if status.to_i == 503
          json = parse(refusal_body(sock, headers))
          return Unreachable.new(attempts: 1, detail: json&.[]("detail"))
        end

        body = refusal_body(sock, headers)
        json = parse(body)
        detail = json&.[]("detail") || (body unless body.empty?)
        code = status.to_i
        error = json&.[]("error")
        outcome = if code == 404
                    Refused.new(reason: :unknown_session, detail: detail, status: code)
                  elsif BridgeSecret.refused?(code, json || body)
                    Refused.new(reason: :bridge_secret, detail: detail, status: code)
                  elsif code == 403 && error == "proxied"
                    Refused.new(reason: :proxied, detail: detail, status: code)
                  elsif code == 403 && error == "cross_origin"
                    Refused.new(reason: :cross_origin, detail: detail, status: code)
                  elsif code == 502 && error == BridgeSecret::ERROR
                    Refused.new(reason: :bridge_secret, detail: detail, status: code)
                  else
                    Refused.new(reason: :other, detail: detail, status: code)
                  end
        outcome
      ensure
        sock&.close unless (status || 0).to_i == 200
      end

      # A refusal body is bounded and interruptible by closing its socket.
      # Content-Length replies stop at their declared size; older Bridges
      # without it are read through EOF.
      def refusal_body(sock, headers)
        length = headers.to_h["content-length"]&.to_i
        limit = length&.between?(0, BODY_LIMIT) ? length : BODY_LIMIT
        body = +""
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BODY_TIMEOUT
        while body.bytesize < limit
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break unless left.positive? && sock.wait_readable(left)

          body << sock.readpartial(limit - body.bytesize)
        end
        body.force_encoding(Encoding::UTF_8).scrub
      rescue IOError, SystemCallError
        body.force_encoding(Encoding::UTF_8).scrub
      end

      def parse(body)
        json = JSON.parse(body)
        json if json.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
      private_class_method :parse
    end
  end
end
