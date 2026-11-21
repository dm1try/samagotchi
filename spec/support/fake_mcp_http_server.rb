# frozen_string_literal: true

require "json"
require "webrick"

# A remote MCP server for the mcp bundle's specs (spec/samagotchi/plugin/
# mcp_bundle_remote_spec.rb): WEBrick on 127.0.0.1, answering whatever id it
# is sent. Modern (server/discover, JSON answers) unless +legacy+, which
# answers discover 404 and initialize and the rest as SSE, the way context7
# answers its legacy requests. +token+, when set, is the only bearer token it
# takes (a 401 with an empty body otherwise); +down+ answers 503 to every
# request while true; +hold+, while true, keeps each request waiting
# (#holding counts them) before its answer. Wrap examples in
# FakeProviderServer.without_webmock.
class FakeMcpHttpServer
  TOOLS = [
    { name: "echo", description: "Echo the text back.",
      inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
    { name: "path", description: "Answers the path it is given.",
      inputSchema: { type: "object", properties: { path: { type: "string" } } } }
  ].freeze

  Seen = Data.define(:rpc_method, :headers, :json)

  attr_accessor :token, :down, :legacy, :hold

  def self.start(**) = new(**).tap(&:start)

  def initialize(legacy: false, token: nil)
    @legacy = legacy
    @token = token
    @down = false
    @hold = false
    @holding = 0
    @mutex = Mutex.new
    @requests = []
  end

  def start
    @server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    @server.mount_proc("/") { |req, res| handle(req, res) }
    @thread = Thread.new { @server.start }
    self
  end

  def stop
    @hold = false
    @server&.shutdown
    @thread&.join(0.2) || @thread&.kill
  end

  def url = "http://127.0.0.1:#{@server.config[:Port]}/mcp"

  def requests = @mutex.synchronize { @requests.dup }

  # The JSON-RPC methods it was sent, in order.
  def rpc_methods = requests.map(&:rpc_method)

  def holding = @mutex.synchronize { @holding }

  private

  def handle(req, res)
    message = JSON.parse(req.body.to_s)
    @mutex.synchronize do
      @requests << Seen.new(rpc_method: message["method"], headers: req.header.transform_values { |v| v.join(", ") }, json: message)
    end
    held if hold
    return res.status = 503 if down
    return res.status = 401 if token && req["authorization"] != "Bearer #{token}"

    answer(message, res)
  end

  def held
    @mutex.synchronize { @holding += 1 }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    sleep(0.02) while hold && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline # sleep-ok: the server holding
  ensure
    @mutex.synchronize { @holding -= 1 }
  end

  def answer(message, res)
    return res.status = 202 unless message.key?("id")
    return res.status = 404 if legacy && message["method"] == "server/discover"

    result = case message["method"]
             when "server/discover" then { supportedVersions: ["2026-07-28"], instructions: "A remote fake. It echoes." }
             when "initialize" then { protocolVersion: "2025-11-25", instructions: "A remote fake. It echoes." }
             when "tools/list" then { tools: TOOLS }
             when "tools/call"
               args = message.dig("params", "arguments") || {}
               text = message.dig("params", "name") == "path" ? args["path"] : "echo: #{args["text"]}"
               { content: [{ type: "text", text: text }] }
             end
    body = JSON.generate(jsonrpc: "2.0", id: message["id"], result: result)
    if legacy
      res["Content-Type"] = "text/event-stream"
      res.body = "event: message\ndata: #{body}\n\n"
    else
      res["Content-Type"] = "application/json"
      res.body = body
    end
  end
end
