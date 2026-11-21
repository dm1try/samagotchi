# frozen_string_literal: true

require_relative "../mcp_server/protocol"
require_relative "../mcp_server/http"
require_relative "../mcp_server/tools"
require_relative "../mcp_server/text"
require_relative "../session_inbox"
require_relative "ask_routes"
require_relative "request_body"

module Samagotchi
  module Web
    # POST /api/mcp: chi as an MCP server on chi web (McpServer::Http, one
    # JSON answer a POST, each call within McpServer::Tools::SLICE), for an
    # MCP host that speaks HTTP. Behind the gates every owner route has
    # (the Host check, a foreign Origin's 403, the token: none on loopback
    # without web.public_url, Bearer on the LAN or a public URL; a
    # participant's token is refused), with chi web's own {error, detail}
    # bodies there; a tokenless request's 401 adds WWW-Authenticate:
    # Bearer, so a host says it needs a token rather than look for OAuth.
    # GET 405 (no stream), DELETE 200 (a legacy host closing its session).
    # Included in App through SessionAccessRoutes; its helpers
    # (request_body, session_access, live_bridge_client, error_response)
    # and ivars (@manager, @hub, @wait_poll_interval, @server_running)
    # answer. See docs/mcp-server.md.
    module McpRoute
      # GET /api/info's feature: this chi web serves POST /api/mcp.
      FEATURE = "mcp"
      PATH = %r{\A/api/mcp\z}
      # A POST's body cap: a chi_ask prompt at its 16 KiB limit, every byte
      # JSON-escaped (a control character's \u0000 is 6 bytes), plus the
      # envelope, so a host gets the tool's "the message is N bytes" over
      # the limit, not chi web's 413.
      BODY_LIMIT = (6 * SessionInbox::NOTE_MAX_BYTES) + (16 * 1024)
      # App::ROUTES' rows for the path (all :owner).
      ROUTES = [["POST", PATH, :handle_mcp, :owner], ["GET", PATH, :handle_mcp_get, :owner],
                ["DELETE", PATH, :handle_mcp_delete, :owner]].freeze

      # The tools' backend on chi web: the ask's (its manager and Bridge),
      # whose answer also closes the page's card once the worker took it,
      # as POST …/answer does.
      class McpAccess < AskRoutes::AskAccess
        def initialize(access, hub:, **)
          super(access, **)
          @hub = hub
        end

        def answer(id, question_id:, **)
          reply = __getobj__.answer(id, question_id: question_id, **)
          @hub&.resolve_question(id, question_id: question_id) if reply&.status == 200
          reply
        end
      end

      private

      def handle_mcp(req)
        body = request_body(req, BODY_LIMIT, what: "an MCP request")
        McpServer::Http.new(mcp_protocol).call(req.env, body)
      end

      def handle_mcp_get(_req)
        text = JSON.generate({ error: "method_not_allowed", detail: "POST an MCP request; this server opens no stream" })
        [405, { "Content-Type" => "application/json", "Allow" => "POST, DELETE", "Content-Length" => text.bytesize.to_s }, [text]]
      end

      # Nothing is kept for a legacy session id: nothing to end.
      def handle_mcp_delete(_req) = [200, { "Content-Length" => "0" }, []]

      def mcp_protocol
        bridge = ->(sid) { live_bridge_client(sid, within: McpServer::Tools::CAP) }
        access = McpAccess.new(session_access, hub: @hub, manager: @manager, bridge: bridge, poll_interval: @wait_poll_interval)
        stopping = -> { !@server_running.call }
        exchange = ->(backend) { SessionAccess::Exchange.new(backend, cancelled: stopping) }
        tools = McpServer::Tools.new(access, exchange: exchange, cancelled: stopping)
        McpServer::Protocol.new(tools: tools, instructions: McpServer::Text::INSTRUCTIONS)
      end

      # The /api/ 401 (App#unauthorized's), with WWW-Authenticate: Bearer
      # on this path.
      def api_unauthorized(req, detail)
        status, headers, body = error_response(401, "unauthorized", detail)
        headers = headers.merge("WWW-Authenticate" => "Bearer") if PATH.match?(req.path_info)
        [status, headers, body]
      end
    end
  end
end
