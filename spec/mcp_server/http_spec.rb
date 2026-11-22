# frozen_string_literal: true

require "spec_helper"
require "samagotchi/mcp_server/protocol"
require "samagotchi/mcp_server/http"

# McpServer::Http on a fake tools object: what a POST's body and headers
# answer before chi web's gates matter (spec/web/mcp_route_spec.rb has the
# route through App).
RSpec.describe Samagotchi::McpServer::Http do
  let(:tools) do
    double("tools").tap do |fake|
      allow(fake).to receive(:list).and_return([{ name: "echo" }])
      allow(fake).to receive(:call) { |_name, arguments| { content: [{ type: "text", text: arguments["text"].to_s }], isError: false } }
    end
  end
  let(:http) { described_class.new(Samagotchi::McpServer::Protocol.new(tools: tools)) }
  let(:legacy_session) { { "HTTP_MCP_SESSION_ID" => "s-1" } }

  def post(body, env = {})
    status, headers, chunks = http.call(env, body.is_a?(String) ? body : JSON.generate(body))
    text = chunks.join
    [status, headers, text.empty? ? nil : JSON.parse(text)]
  end

  it "answers a body that isn't valid UTF-8 with 400 -32700, never raising" do
    status, _headers, body = post(%({"jsonrpc":"2.0","id":3,"method":"ping","params":{"x":"\xff"}}).b, legacy_session)
    expect([status, body["id"], body["error"]["code"]]).to eq([400, 3, -32_700])
  end

  it "answers an Mcp-Name that isn't UTF-8 (base64 of a bad byte) with 400 -32020, not a raise" do
    env = { "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28", "HTTP_MCP_METHOD" => "tools/call", "HTTP_MCP_NAME" => "=?base64?/w==?=" }
    message = { jsonrpc: "2.0", id: 4, method: "tools/call",
                params: { name: "echo", _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } } }
    status, _headers, body = post(message, env)
    expect([status, body["id"], body["error"]["code"]]).to eq([400, 4, -32_020])
    expect(body["error"]["message"]).to include("\uFFFD")
  end

  it "serves a legacy POST with a legacy MCP-Protocol-Version or none, and refuses another with 400 -32600" do
    ping = { jsonrpc: "2.0", id: 5, method: "ping" }
    [nil, "2025-06-18", "2025-11-25"].each do |version|
      expect(post(ping, legacy_session.merge("HTTP_MCP_PROTOCOL_VERSION" => version).compact)[0]).to eq(200), version.inspect
    end
    %w[2099-01-01 2026-07-28 2025-03-26].each do |version|
      status, _headers, body = post(ping, legacy_session.merge("HTTP_MCP_PROTOCOL_VERSION" => version))
      expect([status, body["id"], body["error"]["code"]]).to eq([400, 5, -32_600]), version
      expect(body["error"]["message"]).to include("Unsupported protocol version #{version}")
    end
    # initialize negotiates in its body.
    expect(post({ jsonrpc: "2.0", id: 6, method: "initialize", params: {} }, "HTTP_MCP_PROTOCOL_VERSION" => "2099-01-01")[0]).to eq(200)
  end

  it "answers a body that isn't an object (a batch, null, a number) with -32600, never raising" do
    ['[{"jsonrpc":"2.0","id":1,"method":"ping"}]', "null", "3", '"x"'].each do |text|
      [{}, legacy_session].each do |env|
        status, _headers, body = post(text, env)
        expect([status, body["error"]["code"], body["id"]]).to eq([400, -32_600, nil]), text
      end
    end
  end

  it "uses a null id for a modern object-id header mismatch" do
    env = { "HTTP_MCP_PROTOCOL_VERSION" => "2099-01-01", "HTTP_MCP_METHOD" => "tools/list" }
    message = { jsonrpc: "2.0", id: { bad: true }, method: "tools/list",
                params: { _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } } }
    status, _headers, body = post(message, env)
    expect([status, body["id"], body["error"]["code"]]).to eq([400, nil, -32_020])
  end

  it "uses a null id for a legacy array-id session refusal" do
    message = { jsonrpc: "2.0", id: [1], method: "tools/list" }
    status, _headers, body = post(message)
    expect([status, body["id"], body["error"]["code"], body["error"]["message"]]).to eq(
      [400, nil, -32_600, "Bad Request: Missing session ID"]
    )
  end
end
