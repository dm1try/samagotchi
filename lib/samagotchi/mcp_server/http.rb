# frozen_string_literal: true

require "json"
require "securerandom"
require_relative "protocol"

module Samagotchi
  module McpServer
    # MCP over HTTP, one POST at a time (chi web's POST /api/mcp): one
    # JSON-RPC message in, a JSON answer out (no SSE: spike D2). The era is
    # decided per POST (Protocol.era_of). A modern request's headers must
    # match its body before anything runs (MCP-Protocol-Version = _meta's
    # version, Mcp-Method = method, Mcp-Name = params.name on tools/call):
    # 400 -32020 otherwise. A legacy initialize is handed a fresh
    # Mcp-Session-Id, which every later legacy POST must carry (400
    # "Missing session ID" without one, as the reference server answers);
    # any well-formed one is served. Nothing is stored for it: the tools
    # hold no per-connection state, so an id only marks a legacy client
    # that did initialize. The transport's gates (Host, Origin, the token)
    # are the caller's.
    class Http
      JSON_HEADERS = { "Content-Type" => "application/json", "Cache-Control" => "no-store" }.freeze
      SESSION_HEADER = "Mcp-Session-Id"
      SESSION_ID = /\A[\x21-\x7e]{1,128}\z/
      ENCODED = /\A=\?base64\?(.*)\?=\z/m

      # @param protocol [Protocol]
      def initialize(protocol)
        @protocol = protocol
      end

      # @param env [Hash] the Rack env (its HTTP_MCP_* headers)
      # @param body [String] the request's body as read
      # @return [Array(Integer, Hash, Array<String>)]
      def call(env, body)
        message = JSON.parse(body.to_s)
      rescue JSON::ParserError => e
        respond(400, Protocol.error_body(nil, Protocol::PARSE_ERROR, "Parse error: #{e.message}"))
      else
        era = Protocol.era_of(message)
        refused = era == :modern ? header_refusal(env, message) : session_refusal(env, message)
        return respond(400, refused) if refused

        answer = @protocol.handle(message, era: era)
        return [202, {}, []] unless answer

        headers = {}
        if era == :legacy && message["method"] == "initialize" && answer.body.key?(:result)
          headers[SESSION_HEADER] = SecureRandom.uuid
        end
        respond(answer.status, answer.body, headers)
      end

      private

      def header_refusal(env, message)
        params = message["params"].is_a?(Hash) ? message["params"] : {}
        id = message["id"]
        version = env["HTTP_MCP_PROTOCOL_VERSION"]
        meta_version = params.dig("_meta", VERSION_META)
        unless version == meta_version
          return mismatch(id, version.nil? ? "MCP-Protocol-Version header is missing" : "MCP-Protocol-Version header " \
                                                                                        "#{version} does not match _meta's #{meta_version}")
        end
        method = env["HTTP_MCP_METHOD"]
        return mismatch(id, "Mcp-Method header is required on the modern path") if method.nil?
        return mismatch(id, "Mcp-Method header value '#{method}' does not match body value '#{message["method"]}'") unless method == message["method"]
        return nil unless message["method"] == "tools/call"

        name = decoded(env["HTTP_MCP_NAME"])
        return mismatch(id, "Mcp-Name header is required on tools/call") if name.nil?

        name == params["name"] ? nil : mismatch(id, "Mcp-Name header value '#{name}' does not match body value '#{params["name"]}'")
      end

      def mismatch(id, words) = Protocol.error_body(id, Protocol::HEADER_MISMATCH, "Header mismatch: #{words}")

      # A legacy request past initialize carries its session id.
      def session_refusal(env, message)
        return nil if !message.is_a?(Hash) || message["method"] == "initialize"

        session = env["HTTP_MCP_SESSION_ID"]
        return nil if session.is_a?(String) && SESSION_ID.match?(session)

        Protocol.error_body(message["id"], Protocol::INVALID_REQUEST, "Bad Request: Missing session ID")
      end

      # A header in the =?base64?…?= form decoded (a name that isn't ASCII).
      def decoded(value)
        return value unless value&.match?(ENCODED)

        value[ENCODED, 1].unpack1("m").force_encoding(Encoding::UTF_8)
      end

      def respond(status, body, headers = {})
        text = JSON.generate(body)
        [status, JSON_HEADERS.merge("Content-Length" => text.bytesize.to_s, **headers), [text]]
      end
    end
  end
end
