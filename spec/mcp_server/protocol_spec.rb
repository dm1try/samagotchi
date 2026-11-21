# frozen_string_literal: true

require "spec_helper"
require "samagotchi/mcp_server/protocol"

# McpServer::Protocol on a fake tools object: the spike's Q1 table (the
# rows that aren't HTTP-only), in both eras.
RSpec.describe Samagotchi::McpServer::Protocol do
  let(:calls) { [] }
  let(:tools) do
    double("tools").tap do |fake|
      allow(fake).to receive(:list).and_return([{ name: "echo", description: "says it back", inputSchema: { type: "object" } }])
      allow(fake).to receive(:call) do |name, arguments|
        calls << [name, arguments]
        { content: [{ type: "text", text: arguments["text"].to_s }], structuredContent: { said: arguments["text"] }, isError: false }
      end
    end
  end
  let(:protocol) { described_class.new(tools: tools, instructions: "be brief", version: "9.9.9") }
  let(:meta) { { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } }

  def modern(method, params = {}, id: 1) = { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params.merge("_meta" => meta) }
  def legacy(method, params = nil, id: 1) = { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }.compact

  def body(answer) = JSON.parse(JSON.generate(answer.body))

  describe "the modern era" do
    it "answers server/discover with its versions, tools capability and no-cache hints" do
      answer = protocol.handle(modern("server/discover"))
      expect(answer).to have_attributes(status: 200, era: :modern)
      expect(body(answer)["result"]).to eq(
        "supportedVersions" => ["2026-07-28"], "capabilities" => { "tools" => {} }, "instructions" => "be brief",
        "ttlMs" => 0, "cacheScope" => "private", "resultType" => "complete",
        "_meta" => { "io.modelcontextprotocol/serverInfo" => { "name" => "chi", "version" => "9.9.9" } }
      )
    end

    it "stamps every result with resultType and serverInfo; tools/list carries ttlMs and cacheScope" do
      listed = body(protocol.handle(modern("tools/list")))["result"]
      expect(listed).to include("tools" => [include("name" => "echo")], "ttlMs" => 0, "cacheScope" => "private",
                                "resultType" => "complete")
      called = body(protocol.handle(modern("tools/call", { "name" => "echo", "arguments" => { "text" => "hi" } })))["result"]
      expect(called).to include("content" => [{ "type" => "text", "text" => "hi" }], "isError" => false,
                                "resultType" => "complete", "_meta" => include("io.modelcontextprotocol/serverInfo"))
      expect(calls).to eq([["echo", { "text" => "hi" }]])
    end

    it "refuses an unsupported version with -32022 and what it supports (400)" do
      message = modern("server/discover").tap { |m| m["params"]["_meta"] = { meta.keys.first => "2099-01-01" } }
      answer = protocol.handle(message)
      expect(answer.status).to eq(400)
      expect(body(answer)["error"]).to include("code" => -32_022,
                                               "data" => { "supported" => ["2026-07-28"], "requested" => "2099-01-01" })
    end

    it "has no initialize or ping (-32601, 404)" do
      %w[initialize ping].each do |method|
        answer = protocol.handle(modern(method), era: :modern)
        expect(answer.status).to eq(404)
        expect(body(answer)["error"]["code"]).to eq(-32_601)
      end
    end
  end

  describe "the legacy era" do
    it "answers initialize with the client's version when it knows it, else 2025-11-25" do
      %w[2025-06-18 2025-03-26 2025-11-25].each do |version|
        result = body(protocol.handle(legacy("initialize", { "protocolVersion" => version })))["result"]
        expect(result).to eq("protocolVersion" => version, "capabilities" => { "tools" => {} },
                             "serverInfo" => { "name" => "chi", "version" => "9.9.9" }, "instructions" => "be brief")
      end
      expect(body(protocol.handle(legacy("initialize", { "protocolVersion" => "2024-01-01" })))["result"]["protocolVersion"])
        .to eq("2025-11-25")
    end

    it "answers ping, tools/list without the modern stamps, and tools/call" do
      expect(body(protocol.handle(legacy("ping")))["result"]).to eq({})
      listed = body(protocol.handle(legacy("tools/list")))["result"]
      expect(listed.keys).to eq(["tools"])
      called = body(protocol.handle(legacy("tools/call", { "name" => "echo", "arguments" => { "text" => "x" } })))["result"]
      expect(called).not_to include("resultType", "_meta")
      expect(called["structuredContent"]).to eq("said" => "x")
    end

    it "has no server/discover (-32601)" do
      expect(body(protocol.handle(legacy("server/discover")))["error"]["code"]).to eq(-32_601)
    end
  end

  it "decides a message's era: initialize legacy, a _meta version modern, else legacy" do
    expect(described_class.era_of(legacy("initialize", { "_meta" => meta }))).to eq(:legacy)
    expect(described_class.era_of(modern("tools/list"))).to eq(:modern)
    expect(described_class.era_of(legacy("tools/list"))).to eq(:legacy)
  end

  it "serves a locked era: a modern connection's initialize is -32601 even with no _meta" do
    expect(protocol.handle(legacy("initialize", { "protocolVersion" => "2025-06-18" }), era: :modern).status).to eq(404)
    expect(protocol.handle(legacy("tools/list"), era: :legacy).status).to eq(200)
  end

  it "answers nothing for a notification, in either era" do
    expect(protocol.handle({ "jsonrpc" => "2.0", "method" => "notifications/initialized" })).to be_nil
    expect(protocol.handle({ "jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => { "_meta" => meta } })).to be_nil
  end

  it "answers -32601 (404) for what it doesn't serve: prompts, resources, subscriptions, anything else" do
    %w[prompts/list resources/list subscriptions/listen foo/bar].each do |method|
      [modern(method), legacy(method)].each do |message|
        answer = protocol.handle(message)
        expect([answer.status, body(answer)["error"]["code"]]).to eq([404, -32_601]), method
      end
    end
  end

  it "answers an unknown tool and non-object arguments with -32602" do
    expect(body(protocol.handle(legacy("tools/call", { "name" => "nope" })))["error"]["code"]).to eq(-32_602)
    expect(body(protocol.handle(legacy("tools/call", { "name" => "echo", "arguments" => [1] })))["error"]["code"]).to eq(-32_602)
    expect(calls).to be_empty
  end

  it "answers -32700 for unparseable text and -32600 for a malformed message (400)" do
    parsed = protocol.handle_text("{not json")
    expect([parsed.status, body(parsed)["error"]["code"]]).to eq([400, -32_700])
    [[1, 2], { "id" => 3, "method" => "ping" }, { "jsonrpc" => "2.0", "id" => 4, "method" => 5 },
     { "jsonrpc" => "2.0", "id" => 5, "method" => "ping", "params" => [] }].each do |message|
      answer = protocol.handle(message)
      expect([answer.status, body(answer)["error"]["code"]]).to eq([400, -32_600]), message.inspect
    end
  end

  it "answers -32603 for an exception outside a tool's own rescue, never raising" do
    allow(tools).to receive(:call).and_raise(RuntimeError, "boom")
    answer = protocol.handle(legacy("tools/call", { "name" => "echo" }, id: 9))
    expect(answer.status).to eq(500)
    expect(body(answer)).to include("id" => 9, "error" => include("code" => -32_603, "message" => include("boom")))
  end
end
