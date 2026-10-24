# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"
require_relative "crypto"

module Samagotchi
  module Web
    module Push
      # One push to one device: the payload encrypted for its keys
      # (Crypto.encrypt), POSTed to its endpoint with chi web's VAPID header,
      # and the push service's answer as a Result. No retry (P1). See
      # docs/internals/web-push.md.
      class Client
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 10

        # +status+ :ok (201/200/202), :gone (404/410: the device dropped
        # it), :bad_jwt (403 BadJwtToken: the push service refused chi's
        # VAPID token) or :failed; +code+ the HTTP status (nil when none
        # came), +error+ a short word for a failure, +ms+ the call's time.
        Result = Data.define(:status, :code, :ms, :error) do
          def initialize(error: nil, **) = super
          def ok? = status == :ok
        end

        # Net::HTTP over TLS, the timeouts above; a transport takes the URI
        # and the request and returns the response (specs inject one).
        TLS = lambda do |uri, request|
          Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(request)
          end
        end

        # What a failed connection says in the log: never its message (it
        # may carry the endpoint).
        NETWORK_ERRORS = [SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Timeout::Error,
                          Net::HTTPBadResponse, Net::ProtocolError].freeze

        # @param key [OpenSSL::PKey::EC] chi web's VAPID key (Store#vapid_key)
        # @param contact [String] the VAPID sub (Crypto.valid_sub?)
        # @param transport [#call] (uri, request) → Net::HTTPResponse
        # @param clock [#call] the Time now (the JWT's exp)
        # @param monotonic [#call] seconds, for +ms+
        def initialize(key:, contact:, transport: TLS, clock: -> { Time.now },
                       monotonic: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          @key = key
          @contact = contact
          @transport = transport
          @clock = clock
          @monotonic = monotonic
        end

        # Never the key.
        def inspect = "#<#{self.class.name} #{@contact}>"
        alias to_s inspect

        # @param sub [Store::Sub]
        # @param payload [Hash] the JSON the service worker reads
        # @param ttl [Integer] seconds the push service keeps it for an
        #   offline device
        # @param urgency ["high", "normal"]
        # @return [Result]
        def deliver(sub, payload, ttl:, urgency:)
          started = @monotonic.call
          response = @transport.call(URI(sub.endpoint), request(sub, payload, ttl: ttl, urgency: urgency))
          result_for(response, ms(started))
        rescue *NETWORK_ERRORS => e
          Result.new(status: :failed, code: nil, ms: ms(started), error: e.is_a?(Timeout::Error) ? "timeout" : e.class.name)
        end

        private

        def request(sub, payload, ttl:, urgency:)
          body = Crypto.encrypt(JSON.generate(payload), p256dh: sub.p256dh_bytes, auth: sub.auth_bytes)
          Net::HTTP::Post.new(URI(sub.endpoint)).tap do |req|
            req["Content-Encoding"] = "aes128gcm"
            req["Content-Type"] = "application/octet-stream"
            req["TTL"] = ttl.to_i.to_s
            req["Urgency"] = urgency
            req["Authorization"] = Crypto.vapid_authorization(sub.endpoint, key: @key, sub: @contact, now: @clock.call)
            req.body = body
          end
        end

        def result_for(response, elapsed)
          code = response.code.to_i
          status = case code
                   when 200, 201, 202 then :ok
                   when 404, 410 then :gone
                   when 403 then response.body.to_s.include?("BadJwtToken") ? :bad_jwt : :failed
                   else :failed
                   end
          Result.new(status: status, code: code, ms: elapsed, error: status == :failed ? code.to_s : nil)
        end

        def ms(started) = ((@monotonic.call - started) * 1000).round
      end
    end
  end
end
