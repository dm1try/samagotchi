# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"
require "samagotchi/testing/fake_http"
require_relative "../../support/mcp_bundle"
require_relative "../../support/fake_provider_server"

# The mcp bundle's HTTP client (Plugin::HttpClient) against FakeProviderServer:
# real sockets, never the network.
RSpec.describe "The mcp bundle's HTTP client" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:plugin_module) do
    Module.new.tap { |mod| mod.module_eval(File.read(File.join(MCP_SHIPPED, "plugin.rb")), "plugin.rb", 1) }
  end
  let(:client_class) { plugin_module::Plugin::HttpClient }
  let(:errors) { plugin_module::Plugin::Client }
  let(:server) { FakeProviderServer.start }
  let(:url) { "#{server.root_url}/mcp?key=QUERY-SECRET" }
  let(:logged) { [] }
  let(:token) { -> {} }
  let(:headers) { { "X-Example" => "HEADER-SECRET" } }
  let(:http) { Samagotchi::Plugin::Http.new(bundle: "mcp") }
  let(:client) do
    client_class.new(url, headers: headers, token: token, http: http, log: ->(event, **fields) { logged << [event, fields] })
  end

  after { server.stop }

  def json_rpc(id, result) = { jsonrpc: "2.0", id: id, result: result }
  def rpc_error(id, code, message, data = nil) = { jsonrpc: "2.0", id: id, error: { code: code, message: message, data: data }.compact }
  def sse(*messages) = messages.map { |m| "event: message\ndata: #{JSON.generate(m)}\n\n" }.join
  def modern_discover = server.enqueue("/mcp", json: json_rpc(1, { supportedVersions: ["2026-07-28"], instructions: "Hi." }))
  def methods_sent = server.requests.map { |r| r.json["method"] }

  # initialize (SSE, as context7 answers it) and notifications/initialized.
  def legacy_answers(id, session: nil)
    server.enqueue("/mcp", sse: sse(json_rpc(id, { protocolVersion: "2025-11-25", instructions: "Old." })),
                           headers: session ? { "Mcp-Session-Id" => session } : {})
    server.enqueue("/mcp", status: 202, body: "")
  end

  describe "the modern era" do
    it "discovers, then sends each request with _meta and the modern headers" do
      modern_discover
      server.enqueue("/mcp", json: json_rpc(2, { content: [{ type: "text", text: "ok" }] }))

      expect(client.handshake(timeout: 5, cancelled: nil)).to include("instructions" => "Hi.")
      expect(client.era).to eq(:modern)
      result = client.request("tools/call", { name: "get_me", arguments: { a: 1 } }, timeout: 5)

      expect(result["content"].first["text"]).to eq("ok")
      call = server.requests.last
      expect(call.json["params"]).to eq(
        "name" => "get_me", "arguments" => { "a" => 1 },
        "_meta" => { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                     "io.modelcontextprotocol/clientInfo" => { "name" => "chi", "version" => Samagotchi::VERSION },
                     "io.modelcontextprotocol/clientCapabilities" => {} }
      )
      expect(%w[mcp-protocol-version mcp-method mcp-name accept content-type x-example user-agent].map { |h| call.header(h) })
        .to eq(["2026-07-28", "tools/call", "get_me", "application/json, text/event-stream", "application/json",
                "HEADER-SECRET", Samagotchi::USER_AGENT])
      expect(call.header("mcp-session-id")).to be_nil
      expect(server.requests.first.header("mcp-method")).to eq("server/discover")
    end

    it "takes the answer from an SSE stream, logging and skipping a notification before it" do
      modern_discover
      server.enqueue("/mcp", sse: sse({ jsonrpc: "2.0", method: "notifications/progress", params: {} },
                                      { jsonrpc: "2.0", id: "srv-1", method: "ping" }, json_rpc(2, { tools: [] })))
      client.handshake(timeout: 5, cancelled: nil)

      expect(client.request("tools/list", nil, timeout: 5)).to eq("tools" => [])
      expect(logged).to include(["server_notification", { method: "notifications/progress" }],
                                ["server_notification", { method: "ping" }])
    end

    it "calls a stream that ends without the answer an error" do
      modern_discover
      server.enqueue("/mcp", sse: sse({ jsonrpc: "2.0", method: "notifications/progress", params: {} }))
      client.handshake(timeout: 5, cancelled: nil)

      expect { client.request("tools/list", nil, timeout: 5) }
        .to raise_error(errors::Error, "the server closed the stream without an answer")
    end

    it "refuses an input request chi can't answer, and a request before the handshake" do
      expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(errors::Error, "tools/list before the handshake")
      modern_discover
      server.enqueue("/mcp", json: json_rpc(2, { resultType: "input_required" }))
      client.handshake(timeout: 5, cancelled: nil)

      expect { client.request("tools/call", { name: "x" }, timeout: 5) }
        .to raise_error(errors::Error, "the server asked for input chi can't give yet")
    end
  end

  describe "the fallback to legacy" do
    {
      "a JSON-RPC error (-32601)" => { json: { jsonrpc: "2.0", id: 1, error: { code: -32_601, message: "Method not found" } } },
      "a 400" => { status: 400, body: "bad request" },
      "a 404 with a JSON body" => { status: 404, json: { error: "nope" } },
      "a 405" => { status: 405, body: "" },
      "an unexpected content type" => { body: "<html></html>", headers: { "Content-Type" => "text/html" } },
      "a stream without the answer" => { sse: "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/x\"}\n\n" },
      "a result without 2026-07-28" => { json: { jsonrpc: "2.0", id: 1, result: { supportedVersions: ["2099-01-01"] } } }
    }.each do |what, discover|
      it "follows #{what} to discover with initialize, then initialized" do
        server.enqueue("/mcp", **discover)
        legacy_answers(2)

        expect(client.handshake(timeout: 5, cancelled: nil)).to include("protocolVersion" => "2025-11-25", "instructions" => "Old.")
        expect(client.era).to eq(:legacy)
        expect(methods_sent).to eq(%w[server/discover initialize notifications/initialized])
      end
    end

    it "names the versions a server offered (-32022) when legacy fails too" do
      server.enqueue("/mcp", json: rpc_error(1, -32_022, "Unsupported protocol version", { supported: ["2099-01-01"] }))
      server.enqueue("/mcp", status: 400, body: "no")

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "speaks MCP 2099-01-01, not 2026-07-28 or 2025-11-25 (HTTP 400)")
    end

    it "speaks stateless legacy: no session id, the negotiated version, no _meta" do
      server.enqueue("/mcp", status: 404, body: "")
      legacy_answers(2)
      server.enqueue("/mcp", sse: sse(json_rpc(3, { tools: [{ name: "a" }] })))
      client.handshake(timeout: 5, cancelled: nil)

      expect(client.request("tools/list", nil, timeout: 5)).to eq("tools" => [{ "name" => "a" }])
      initialize, initialized, list = server.requests.drop(1)
      expect(initialize.json["params"]).to eq("protocolVersion" => "2025-11-25", "capabilities" => {},
                                              "clientInfo" => { "name" => "chi", "version" => Samagotchi::VERSION })
      expect([initialize, initialized, list].map { |r| r.header("mcp-protocol-version") }).to eq([nil, "2025-11-25", "2025-11-25"])
      expect(list.json).not_to have_key("params")
      expect(server.requests.map { |r| r.header("mcp-session-id") }.uniq).to eq([nil])
    end

    it "keeps a session id, handshakes again once on its 404, and a second 404 is the error" do
      server.enqueue("/mcp", status: 405, body: "")
      legacy_answers(2, session: "s1")
      server.enqueue("/mcp", status: 404, body: "")
      legacy_answers(4, session: "s2")
      server.enqueue("/mcp", json: json_rpc(5, { tools: [] }))
      client.handshake(timeout: 5, cancelled: nil)

      expect(client.request("tools/list", nil, timeout: 5)).to eq("tools" => [])
      expect(methods_sent).to eq(%w[server/discover initialize notifications/initialized tools/list initialize
                                    notifications/initialized tools/list])
      expect(server.requests.map { |r| r.header("mcp-session-id") }).to eq([nil, nil, "s1", "s1", nil, "s2", "s2"])

      server.enqueue("/mcp", status: 404, body: "")
      legacy_answers(7, session: "s3")
      server.enqueue("/mcp", status: 404, body: "")
      expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(errors::Unavailable, "the session expired (404)")
    end

    it "DELETEs a legacy session at close, best effort" do
      fake = Samagotchi::Testing::FakeHttp.new
      fake.stub(:post, %r{/mcp}) do |request|
        case request.json["method"]
        when "server/discover" then { status: 404 }
        when "initialize" then { events: [JSON.generate(json_rpc(2, {}))], headers: { "Mcp-Session-Id" => "s1" } }
        else { status: 202 }
        end
      end
      fake.stub(:delete, %r{/mcp}, status: 405)
      faked = client_class.new(url, headers: {}, token: -> {}, log: ->(*) {},
                                    http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake))
      faked.handshake(timeout: 5, cancelled: nil)

      expect(faked.close).to be_nil
      delete = fake.requests.last
      expect([delete.method, delete.headers["Mcp-Session-Id"], delete.headers["MCP-Protocol-Version"]]).to eq(%w[DELETE s1 2025-11-25])
      expect(faked.close).to be_nil
      expect(fake.requests.count { |r| r.method == "DELETE" }).to eq(1)
    end
  end

  describe "statuses" do
    it "says a 401 needs a token, and doesn't try legacy" do
      server.enqueue("/mcp", status: 401, body: "")

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "needs a token (401): set bearer_token_env (sign-in comes in a later chi)")
      expect(methods_sent).to eq(["server/discover"])
    end

    context "with a token" do
      let(:token) { -> { "fake-token-value" } }

      it "sends it as a bearer token, and says a 401 refused it" do
        server.enqueue("/mcp", status: 401, body: "bad request: token", headers: { "Content-Type" => "text/plain" })

        expect { client.handshake(timeout: 5, cancelled: nil) }.to raise_error(errors::Unavailable, "refused the token (401)")
        expect(server.requests.last.header("authorization")).to eq("Bearer fake-token-value")
      end
    end

    it "sends nothing when the token's variable is unset" do
      unset = client_class.new(url, headers: {}, token: -> { raise client_class::Refused, "GITHUB_MCP_TOKEN is not set" },
                                    http: http, log: ->(*) {})

      expect { unset.handshake(timeout: 5, cancelled: nil) }.to raise_error(errors::Unavailable, "GITHUB_MCP_TOKEN is not set")
      expect(server.requests).to be_empty
    end

    it "words a 403, a redirect, a JSON-RPC error body and a bare status, never echoing a page" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", status: 403, body: "")
      server.enqueue("/mcp", status: 307, body: "", headers: { "Location" => "https://other.example:8443/new?k=QUERY-SECRET" })
      server.enqueue("/mcp", status: 500, json: rpc_error(4, -32_000, "boom"))
      server.enqueue("/mcp", status: 502, body: "<html>PAGE-TEXT</html>", headers: { "Content-Type" => "text/html" })

      raised = Array.new(4) do
        client.request("tools/list", nil, timeout: 5)
      rescue errors::Error => e
        [e.class, e.message]
      end

      expect(raised).to eq([[client_class::Refused, "refused (403)"],
                            [errors::Unavailable, "redirected (307) to https://other.example:8443: set url: to the new address"],
                            [client_class::RpcError, "boom (-32000)"], [errors::Unavailable, "HTTP 502"]])
    end

    it "calls a server it can't reach Dead, naming host and port" do
      port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
      gone = client_class.new("http://127.0.0.1:#{port}/mcp", headers: {}, token: -> {}, http: http, log: ->(*) {})

      expect { gone.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Dead, "POST 127.0.0.1:#{port}: connection refused")
    end
  end

  describe "time and Stop" do
    it "keeps the call's whole budget on a stream that dribbles keep-alives" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: Array.new(40, ": keep-alive\n\n"), delay: 0.05)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.request("tools/list", nil, timeout: 0.5) }.to raise_error(errors::Timeout, "tools/list timed out after 0.5s")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(1.5, below: 2)
    end

    it "times out a quiet stream with the stdio wording" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: [], hold: true)

      expect { client.request("tools/list", nil, timeout: 0.3) }.to raise_error(errors::Timeout, "tools/list timed out after 0.3s")
    end

    it "stops a call when its cancelled lambda turns true, long before the timeout" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: [], hold: true)
      held = -> { server.holding.positive? }

      expect { client.request("tools/call", { name: "slow" }, timeout: 30, cancelled: held) }
        .to raise_error(errors::Cancelled, "tools/call was cancelled")
    end

    it "stops the handshake on a Stop too (its own watcher: ctx.http has no cancel while a service starts)" do
      server.enqueue("/mcp", sse: [], hold: true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { client.handshake(timeout: 30, cancelled: -> { server.holding.positive? }) }
        .to raise_error(errors::Cancelled, "server/discover was cancelled")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 30)
      expect(Thread.list.count { |t| t.alive? && t.backtrace.to_a.join.include?("watching") }).to eq(0)
    end
  end

  context "with a token and header values" do
    let(:token) { -> { "fake-token-value" } }

    it "never puts them in an error, a log field or inspect" do
      server.enqueue("/mcp", status: 401, body: "fake-token-value HEADER-SECRET")
      texts = []
      begin
        client.handshake(timeout: 5, cancelled: nil)
      rescue errors::Error => e
        texts << e.message
      end

      texts << client.inspect << logged.inspect
      expect(client.inspect).to eq("#<HttpClient #{server.root_url} era=discover>")
      expect(client.label).to eq(server.root_url)
      expect(texts.join).not_to match(/fake-token-value|HEADER-SECRET|QUERY-SECRET|mcp\?/)
    end
  end
end
