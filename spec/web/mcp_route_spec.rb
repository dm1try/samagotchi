# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/session_inbox"
require "samagotchi/owner_lock"
require "samagotchi/bridge_client"

# POST /api/mcp (Web::McpRoute, McpServer::Http): the spike's curl probes as
# request specs, both eras' tools/call, GET and DELETE, and the gates every
# owner route has. The worker is a double of SessionManager.deliver_turn.
RSpec.describe Samagotchi::Web::App, "POST /api/mcp" do
  around do |example|
    Dir.mktmpdir("web-mcp") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    ensure
      @locks&.each(&:release)
    end
  end

  let(:state_dir) { File.join(@tmp, "state").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:hub) { instance_double(Samagotchi::Web::SessionHub, resolve_question: nil) }
  let(:app) do
    described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                        wait_poll_interval: 0.01)
  end
  let(:meta) { { "_meta" => { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } } }
  let(:modern_headers) { { "HTTP_MCP_PROTOCOL_VERSION" => "2026-07-28" } }

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("soft")
  end

  def post(message, headers: {}, app: self.app, method: "POST", host: "127.0.0.1", peer: nil)
    input = message.is_a?(String) ? message : JSON.generate(message)
    env = Rack::MockRequest.env_for("/api/mcp", "HTTP_HOST" => host, method: method, input: (input unless method == "GET"),
                                                "CONTENT_TYPE" => "application/json", **headers)
    env["REMOTE_ADDR"] = peer if peer
    status, response_headers, chunks = app.call(env)
    text = chunks.to_a.join
    [status, response_headers, text.empty? ? nil : JSON.parse(text)]
  end

  def modern(id, method, params = {}, name: nil)
    headers = modern_headers.merge("HTTP_MCP_METHOD" => method)
    headers["HTTP_MCP_NAME"] = name if name
    post({ jsonrpc: "2.0", id: id, method: method, params: params.merge(meta) }, headers: headers)
  end

  def make(status: "idle", pending_question: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: @tmp).tap do |s|
      s.status = status
      s.pending_question = pending_question
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end

  def worker(reply:)
    allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, **|
      Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(id, state_dir: state_dir), reply, enqueued_id: "t1")
      Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => "t1" })
    end
  end

  describe "the modern era" do
    it "answers server/discover as JSON" do
      status, headers, body = modern(1, "server/discover")
      expect([status, headers["Content-Type"]]).to eq([200, "application/json"])
      expect(body["result"]).to include("supportedVersions" => ["2026-07-28"], "resultType" => "complete", "ttlMs" => 0)
    end

    it "runs a tools/call (chi_ask) to the answer" do
      session = make
      worker(reply: "over http")
      status, _headers, body = modern(2, "tools/call", { name: "chi_ask", arguments: { session: session.id, prompt: "hi" } },
                                      name: "chi_ask")
      expect(status).to eq(200)
      expect(body["result"]).to include("isError" => false, "resultType" => "complete",
                                        "content" => [{ "type" => "text", "text" => "over http" }])
    end

    it "takes a base64-encoded Mcp-Name" do
      status, = modern(3, "tools/call", { name: "chi_sessions", arguments: {} }, name: "=?base64?#{["chi_sessions"].pack("m0")}?=")
      expect(status).to eq(200)
    end

    {
      "a wrong Mcp-Method" => [{ "HTTP_MCP_METHOD" => "tools/list" }, "server/discover", "does not match"],
      "a missing Mcp-Method" => [{}, "server/discover", "Mcp-Method header is required"],
      "a missing MCP-Protocol-Version" => [{ "HTTP_MCP_PROTOCOL_VERSION" => nil, "HTTP_MCP_METHOD" => "server/discover" },
                                           "server/discover", "MCP-Protocol-Version header is missing"],
      "a header version unlike _meta's" => [{ "HTTP_MCP_PROTOCOL_VERSION" => "2025-11-25", "HTTP_MCP_METHOD" => "server/discover" },
                                            "server/discover", "does not match _meta's"]
    }.each do |name, (headers, method, words)|
      it "refuses #{name} with 400 -32020 before anything runs" do
        status, _headers, body = post({ jsonrpc: "2.0", id: 7, method: method, params: meta },
                                      headers: modern_headers.merge(headers).compact)
        expect([status, body["error"]["code"]]).to eq([400, -32_020])
        expect(body["error"]["message"]).to include(words)
      end
    end

    it "refuses a wrong or missing Mcp-Name on tools/call (-32020)" do
      expect(modern(9, "tools/call", { name: "chi_wait", arguments: {} }, name: "chi_ask")[2]["error"]["code"]).to eq(-32_020)
      expect(modern(9, "tools/call", { name: "chi_wait", arguments: {} })[0]).to eq(400)
    end

    it "refuses an unsupported version with 400 -32022" do
      status, _headers, body = post({ jsonrpc: "2.0", id: 12, method: "server/discover",
                                      params: { "_meta" => { "io.modelcontextprotocol/protocolVersion" => "2099-01-01" } } },
                                    headers: { "HTTP_MCP_PROTOCOL_VERSION" => "2099-01-01", "HTTP_MCP_METHOD" => "server/discover" })
      expect([status, body["error"]["code"], body["error"]["data"]["supported"]]).to eq([400, -32_022, ["2026-07-28"]])
    end

    it "answers an unknown method 404 -32601, unparseable JSON 400 -32700, a notification 202" do
      expect(modern(13, "foo/bar").then { |s, _h, b| [s, b["error"]["code"]] }).to eq([404, -32_601])
      expect(post("{nope").then { |s, _h, b| [s, b["error"]["code"]] }).to eq([400, -32_700])
      status, _headers, body = post({ jsonrpc: "2.0", method: "notifications/cancelled", params: meta },
                                    headers: modern_headers.merge("HTTP_MCP_METHOD" => "notifications/cancelled"))
      expect([status, body]).to eq([202, nil])
    end
  end

  describe "the legacy era" do
    it "hands initialize a session id, then serves POSTs that carry one and refuses those that don't" do
      status, headers, body = post({ jsonrpc: "2.0", id: 20, method: "initialize", params: { protocolVersion: "2025-06-18" } })
      expect([status, body["result"]["protocolVersion"]]).to eq([200, "2025-06-18"])
      sid = headers["Mcp-Session-Id"]
      expect(sid).to match(/\A[0-9a-f-]{36}\z/)

      expect(post({ jsonrpc: "2.0", method: "notifications/initialized" }, headers: { "HTTP_MCP_SESSION_ID" => sid })[0]).to eq(202)
      session = make
      worker(reply: "legacy answer")
      _status, _headers, called = post({ jsonrpc: "2.0", id: 21, method: "tools/call",
                                         params: { name: "chi_ask", arguments: { session: session.id, prompt: "hi" } } },
                                       headers: { "HTTP_MCP_SESSION_ID" => sid })
      expect(called["result"]["content"].first["text"]).to eq("legacy answer")
      expect(called["result"]).not_to include("resultType")

      status, _headers, body = post({ jsonrpc: "2.0", id: 22, method: "tools/list" })
      expect([status, body["error"]["message"]]).to eq([400, "Bad Request: Missing session ID"])
    end

    it "answers a batch or a null body with JSON-RPC -32600, not chi web's 500" do
      ['[{"jsonrpc":"2.0","id":1,"method":"ping"}]', "null"].each do |text|
        status, _headers, body = post(text, headers: { "HTTP_MCP_SESSION_ID" => "s" })
        expect([status, body.dig("error", "code")]).to eq([400, -32_600]), text
      end
    end

    it "answers GET with 405 and Allow, DELETE with 200 and no body" do
      status, headers, = post(nil, method: "GET")
      expect([status, headers["Allow"]]).to eq([405, "POST, DELETE"])
      status, _headers, body = post("", method: "DELETE", headers: { "HTTP_MCP_SESSION_ID" => "x" })
      expect([status, body]).to eq([200, nil])
    end
  end

  describe "the gates (chi web's own bodies)" do
    it "refuses a foreign Origin with 403 and lets a request without one through" do
      status, _headers, body = post({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
                                    headers: { "HTTP_ORIGIN" => "https://evil.example" })
      expect(status).to eq(403)
      expect(body).not_to include("jsonrpc")
    end

    it "answers a tokenless request on a LAN server with a JSON 401 and WWW-Authenticate: Bearer" do
      lan = described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                                lan: { ip: "192.0.2.10", token: "t0ken" })
      status, headers, body = post({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, app: lan,
                                                                                               host: "192.0.2.10:4567", peer: "192.0.2.20")
      expect([status, headers["WWW-Authenticate"], body["error"]]).to eq([401, "Bearer", "unauthorized"])

      ok, = post({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }, app: lan, host: "192.0.2.10:4567",
                                                                              peer: "192.0.2.20", headers: { "HTTP_AUTHORIZATION" => "Bearer t0ken" })
      expect(ok).to eq(200)
    end

    it "adds WWW-Authenticate to no other /api/ 401" do
      lan = described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                                lan: { ip: "192.0.2.10", token: "t0ken" })
      env = Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "192.0.2.10:4567")
      env["REMOTE_ADDR"] = "192.0.2.20"
      status, headers, = lan.call(env)
      expect([status, headers["WWW-Authenticate"]]).to eq([401, nil])
    end
  end

  it "names the feature in GET /api/info" do
    env = Rack::MockRequest.env_for("/api/info", "HTTP_HOST" => "127.0.0.1")
    _status, _headers, chunks = app.call(env)
    expect(JSON.parse(chunks.to_a.join)["features"]).to include("mcp")
  end

  it "closes the page's card when chi_answer's answer went in" do
    stub_const("Samagotchi::McpServer::Tools::SLICE", 0.2)
    hub_app = described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                                  wait_poll_interval: 0.01, hub: hub)
    session = make(status: "running", pending_question: { id: "q1", question: "Go?", options: %w[Yes No] })
    (@locks ||= []) << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), kind: "worker")
    client = instance_double(Samagotchi::BridgeClient)
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: "{}"))
    allow(Samagotchi::WorkerLink).to receive(:client).and_return(client)
    allow(Samagotchi::SessionManager).to receive(:session_owner).and_return(Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker"))

    _status, _headers, body = post({ jsonrpc: "2.0", id: 5, method: "initialize", params: {} }, app: hub_app)
    expect(body).to include("result")
    _status, _headers, body = post({ jsonrpc: "2.0", id: 6, method: "tools/call",
                                     params: { name: "chi_answer", arguments: { session: session.id, question_id: "q1", option: 1 } } },
                                   app: hub_app, headers: { "HTTP_MCP_SESSION_ID" => "s" })
    expect(body["result"]["structuredContent"]).to include("status" => "running"), body.inspect
    expect(hub).to have_received(:resolve_question).with(session.id, question_id: "q1")
  end
end
