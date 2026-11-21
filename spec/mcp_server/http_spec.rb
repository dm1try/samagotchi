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

  it "answers a body that isn't an object (a batch, null, a number) with -32600, never raising" do
    ['[{"jsonrpc":"2.0","id":1,"method":"ping"}]', "null", "3", '"x"'].each do |text|
      [{}, legacy_session].each do |env|
        status, _headers, body = post(text, env)
        expect([status, body["error"]["code"], body["id"]]).to eq([400, -32_600, nil]), text
      end
    end
  end
end
