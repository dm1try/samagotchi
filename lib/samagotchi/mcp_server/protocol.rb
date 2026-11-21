# frozen_string_literal: true

require "json"
require_relative "../version"

module Samagotchi
  # chi as an MCP server (docs/mcp-server.md): the protocol core
  # (Protocol), the four tools (Tools, their words in Text) and the
  # transports (Stdio for `chi mcp serve`, Http for chi web's POST
  # /api/mcp). Not the `mcp` bundle, which is chi as an MCP client.
  module McpServer
    # The modern revision (stateless, `server/discover`, the version in
    # each request's _meta).
    MODERN_VERSION = "2026-07-28"
    # The legacy revisions an `initialize` may name; the first is the
    # answer to any other. Not 2025-03-26: it allows JSON-RPC batches,
    # which chi doesn't answer (one -32600), and no host sends it (spike
    # Q2: Codex initializes with 2025-06-18; Claude Code is modern).
    LEGACY_VERSIONS = %w[2025-11-25 2025-06-18].freeze
    # Where a modern request names its revision (params._meta).
    VERSION_META = "io.modelcontextprotocol/protocolVersion"
    SERVER_INFO_META = "io.modelcontextprotocol/serverInfo"

    # JSON-RPC in, JSON-RPC out, in both eras; it knows no transport and no
    # chi: +tools+ answers #list (the tools' definitions, each with
    # "name"/:name) and #call(name, arguments) (a tools/call result: content,
    # structuredContent, isError). A tool's refusal is its result's
    # isError; only an unknown tool is a JSON-RPC error here (-32602).
    class Protocol
      # The answer to one message: +status+ the HTTP status a transport
      # that has one answers it with (200, 400, 404, 500), +body+ the
      # JSON-RPC response (a Hash), +era+ :modern or :legacy.
      Answer = Data.define(:status, :body, :era)

      # Text that isn't one JSON value in UTF-8 (.parse); the message says why.
      class Unparseable < StandardError; end

      PARSE_ERROR = -32_700
      INVALID_REQUEST = -32_600
      METHOD_NOT_FOUND = -32_601
      INVALID_PARAMS = -32_602
      INTERNAL_ERROR = -32_603
      # A request's headers don't match its body (HTTP only: Http).
      HEADER_MISMATCH = -32_020
      UNSUPPORTED_VERSION = -32_022

      STATUS = { PARSE_ERROR => 400, INVALID_REQUEST => 400, METHOD_NOT_FOUND => 404, INVALID_PARAMS => 200,
                 INTERNAL_ERROR => 500, HEADER_MISMATCH => 400, UNSUPPORTED_VERSION => 400 }.freeze

      # The era a message is in: an `initialize` is legacy; a modern
      # request names its revision in params._meta; anything else legacy.
      # @return [Symbol] :modern or :legacy
      def self.era_of(message)
        return :legacy unless message.is_a?(Hash)
        return :legacy if message["method"] == "initialize"

        meta = message.dig("params", "_meta") if message["params"].is_a?(Hash)
        meta.is_a?(Hash) && meta.key?(VERSION_META) ? :modern : :legacy
      end

      # One message's text parsed, whatever its encoding tag (a pipe's or
      # a Rack body's bytes are read as UTF-8).
      # @raise [Unparseable] invalid UTF-8, or not JSON
      def self.parse(text)
        text = text.to_s.dup.force_encoding(Encoding::UTF_8)
        raise Unparseable, "invalid UTF-8" unless text.valid_encoding?

        JSON.parse(text)
      rescue JSON::ParserError, EncodingError => e
        raise Unparseable, e.message
      end

      # A request's "id" in text that didn't parse (a lone surrogate
      # escape, a stray byte), so the host can match the -32700 to its
      # call instead of waiting to its own timeout: only when the text names
      # exactly one "id" (one in the params too: nil, never a wrong match).
      ID = /"id"\s*:\s*("(?:[^"\\\x00-\x1f]|\\["\\\/bfnrt]|\\u\h{4})*"|-?(?:0|[1-9]\d*))\s*[,}]/
      def self.recovered_id(text)
        found = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.scan(ID)
        found.size == 1 ? JSON.parse(found.first.first) : nil
      rescue JSON::ParserError
        nil
      end

      # The -32700 answer for +text+ (.parse's +error+), with the id when
      # .recovered_id reads one.
      def self.parse_error_body(text, error)
        error_body(recovered_id(text), PARSE_ERROR, "Parse error: #{error.message}")
      end

      # A response as JSON text, for a transport to write: one with a
      # string that isn't UTF-8 (a worker's reply, a header echoed in a
      # refusal) is written scrubbed, and one that can't be written at all
      # is a -32603 for its id, so no call is left unanswered.
      # @return [String]
      def self.dump(body)
        JSON.generate(body)
      rescue JSON::GeneratorError, EncodingError
        begin
          JSON.generate(scrubbed(body))
        rescue JSON::GeneratorError, EncodingError => e
          id = body.is_a?(Hash) ? body[:id] || body["id"] : nil
          JSON.generate(error_body(scrubbed(id), INTERNAL_ERROR, "Internal error: the answer could not be written (#{e.class})"))
        end
      end

      # +value+ with every string as valid UTF-8 (U+FFFD for a bad byte).
      def self.scrubbed(value)
        case value
        when Hash then value.to_h { |key, item| [scrubbed(key), scrubbed(item)] }
        when Array then value.map { |item| scrubbed(item) }
        when String then utf8(value)
        else value
        end
      end

      # +text+ as UTF-8, a bad byte replaced (a binary string read as UTF-8).
      def self.utf8(text)
        if [Encoding::UTF_8, Encoding::BINARY, Encoding::US_ASCII].include?(text.encoding)
          text.dup.force_encoding(Encoding::UTF_8).scrub
        else
          text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
        end
      end

      # A JSON-RPC error response (also a transport's own, Http's -32020).
      def self.error_body(id, code, message, data: nil)
        error = { code: code, message: message }
        error[:data] = data if data
        { jsonrpc: "2.0", id: id, error: error }
      end

      # @param tools [#list, #call]
      # @param instructions [String, nil] what the server says it is
      # @param name [String] serverInfo's name
      def initialize(tools:, instructions: nil, name: "chi", version: Samagotchi::VERSION)
        @tools = tools
        @instructions = instructions
        @server_info = { name: name, version: version }
      end

      # One line of JSON text: #handle on what it parses to, or -32700.
      # @return [Answer, nil]
      def handle_text(text, era: nil)
        message = self.class.parse(text)
      rescue Unparseable => e
        Answer.new(status: STATUS[PARSE_ERROR], body: self.class.parse_error_body(text, e), era: era || :legacy)
      else
        handle(message, era: era)
      end

      # @param message [Object] one parsed JSON-RPC message
      # @param era [Symbol, nil] the era a stdio connection was locked to
      #   by its first request; nil: this message's own (.era_of)
      # @return [Answer, nil] nil for a notification (or a response)
      def handle(message, era: nil)
        era ||= self.class.era_of(message)
        unless message.is_a?(Hash) && message["jsonrpc"] == "2.0"
          return error(message.is_a?(Hash) ? message["id"] : nil, INVALID_REQUEST, "Invalid Request", era)
        end
        return nil unless message.key?("id") && message.key?("method")

        id = message["id"]
        method = message["method"]
        params = message.fetch("params", {})
        return error(id, INVALID_REQUEST, "Invalid Request", era) unless method.is_a?(String) && params.is_a?(Hash)

        # A modern connection's initialize is -32601 whatever it names.
        if era == :modern && method != "initialize" && (refused = version_refusal(id, params))
          return refused
        end

        dispatch(id, method, params, era)
      rescue StandardError => e
        error(message.is_a?(Hash) ? message["id"] : nil, INTERNAL_ERROR, "Internal error: #{e.message}", era)
      end

      private

      def dispatch(id, method, params, era)
        case [method, era]
        in ["server/discover", :modern] then result(id, discover, era)
        in ["initialize", :legacy] then result(id, initialize_result(params), era)
        in ["ping", :legacy] then result(id, {}, era)
        in ["tools/list", _] then result(id, tools_list(era), era)
        in ["tools/call", _] then call_tool(id, params, era)
        else error(id, METHOD_NOT_FOUND, "Method not found: #{method}", era)
        end
      end

      def version_refusal(id, params)
        requested = params.dig("_meta", VERSION_META)
        return nil if requested == MODERN_VERSION

        error(id, UNSUPPORTED_VERSION, "Unsupported protocol version", :modern,
              data: { supported: [MODERN_VERSION], requested: requested })
      end

      def discover
        { supportedVersions: [MODERN_VERSION], capabilities: { tools: {} }, instructions: @instructions, ttlMs: 0,
          cacheScope: "private" }.compact
      end

      def initialize_result(params)
        asked = params["protocolVersion"]
        version = LEGACY_VERSIONS.include?(asked) ? asked : LEGACY_VERSIONS.first
        { protocolVersion: version, capabilities: { tools: {} }, serverInfo: @server_info,
          instructions: @instructions }.compact
      end

      def tools_list(era)
        listed = { tools: @tools.list }
        era == :modern ? listed.merge(ttlMs: 0, cacheScope: "private") : listed
      end

      def call_tool(id, params, era)
        name = params["name"]
        arguments = params.fetch("arguments", nil) || {}
        unless name.is_a?(String) && tool_names.include?(name)
          return error(id, INVALID_PARAMS, "Unknown tool: #{name.inspect}", era)
        end
        return error(id, INVALID_PARAMS, "arguments is an object", era) unless arguments.is_a?(Hash)

        result(id, @tools.call(name, arguments), era)
      end

      def tool_names = @tools.list.map { |tool| (tool[:name] || tool["name"]).to_s }

      # The one place a result is stamped: a modern one carries resultType
      # and the server's info in _meta.
      def result(id, value, era)
        value = value.merge(resultType: "complete", _meta: { SERVER_INFO_META => @server_info }) if era == :modern
        Answer.new(status: 200, body: { jsonrpc: "2.0", id: id, result: value }, era: era)
      end

      def error(id, code, message, era, data: nil)
        Answer.new(status: STATUS.fetch(code), body: self.class.error_body(id, code, message, data: data), era: era)
      end
    end
  end
end
