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

  let(:plugin_module) { McpPluginFiles.load_module }
  let(:client_class) { plugin_module::Plugin::HttpClient }
  let(:errors) { plugin_module::Plugin::Client }
  let(:server) { FakeProviderServer.start }
  let(:url) { "#{server.root_url}/mcp?key=QUERY-SECRET" }
  let(:logged) { [] }
  let(:token) { client_class::StaticToken.new { nil } }
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

    it "includes server/discover's 503 when legacy fails" do
      server.enqueue("/mcp", status: 503, body: "")
      server.enqueue("/mcp", status: 400, body: "")

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "HTTP 400 (server/discover: HTTP 503)")
    end

    it "includes server/discover's 405 when legacy fails" do
      server.enqueue("/mcp", status: 405, body: "")
      server.enqueue("/mcp", status: 400, body: "")

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "HTTP 400 (server/discover: HTTP 405)")
    end

    it "includes a JSON-RPC server/discover error when legacy fails" do
      server.enqueue("/mcp", json: rpc_error(1, -32_601, "not found"))
      server.enqueue("/mcp", json: rpc_error(2, -32_602, "bad initialize"))

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "bad initialize (-32602) (server/discover: not found (-32601))")
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

    it "recovers on the next call from a re-handshake that failed (the server still coming back after a restart)" do
      server.enqueue("/mcp", status: 405, body: "")
      legacy_answers(2, session: "s1")
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", status: 404, body: "") # tools/list: the session expired
      server.enqueue("/mcp", status: 503, body: "") # initialize again: not up yet
      server.enqueue("/mcp", json: rpc_error(5, -32_603, "warming up")) # initialize: a JSON-RPC error

      expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(errors::Unavailable, "HTTP 503")
      expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(errors::Unavailable, "warming up (-32603)")
      legacy_answers(6, session: "s2")
      server.enqueue("/mcp", json: json_rpc(7, { tools: [] }))

      expect(client.request("tools/list", nil, timeout: 5)).to eq("tools" => [])
      expect(client.era).to eq(:legacy)
      expect(methods_sent.drop(3)).to eq(%w[tools/list initialize initialize initialize notifications/initialized tools/list])
      expect(server.requests.last.header("mcp-session-id")).to eq("s2")
    end

    it "keeps a request's snapshot while another request renews the session" do
      fake = Samagotchi::Testing::FakeHttp.new
      first_call = true
      faked = nil
      fake.stub(:post, %r{/mcp}) do |request|
        case request.json["method"]
        when "server/discover" then { status: 405 }
        when "initialize"
          { json: json_rpc(request.json["id"], { protocolVersion: "2025-11-25" }),
            headers: { "Mcp-Session-Id" => "s#{first_call ? 1 : 2}" } }
        when "notifications/initialized" then { status: 202 }
        when "tools/call"
          if request.headers["Mcp-Session-Id"] == "s1" && first_call
            first_call = false
            expect { faked.request("tools/list", nil, timeout: 5) }.not_to raise_error
            { status: 404 }
          elsif request.headers["Mcp-Session-Id"] == "s1"
            { status: 404 }
          else
            { json: json_rpc(request.json["id"], { content: [] }) }
          end
        when "tools/list"
          if request.headers["Mcp-Session-Id"] == "s1"
            { status: 404 }
          else
            { json: json_rpc(request.json["id"], { tools: [] }) }
          end
        end
      end
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                               http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake))
      faked.handshake(timeout: 5, cancelled: nil)

      expect(faked.request("tools/call", { name: "x" }, timeout: 5)).to eq("content" => [])
      expect(fake.requests.map { |request| request.json["method"] }).to eq(
        %w[server/discover initialize notifications/initialized tools/call tools/list initialize
           notifications/initialized tools/list tools/call]
      )
      expect(fake.requests.last(2).map { |request| request.headers["Mcp-Session-Id"] }).to eq(%w[s2 s2])
    end

    it "keeps the old complete state visible while a re-handshake initializes" do
      fake = Samagotchi::Testing::FakeHttp.new
      observed_era = nil
      initialized = false
      faked = nil
      fake.stub(:post, %r{/mcp}) do |request|
        case request.json["method"]
        when "server/discover" then { status: 405 }
        when "initialize"
          if initialized
            nested = faked.request("tools/list", nil, timeout: 5)
            observed_era = faked.era
            expect(nested).to eq("tools" => [])
            { json: json_rpc(request.json["id"], { protocolVersion: "2025-11-25" }),
              headers: { "Mcp-Session-Id" => "s2" } }
          else
            initialized = true
            { json: json_rpc(request.json["id"], { protocolVersion: "2025-11-25" }),
              headers: { "Mcp-Session-Id" => "s1" } }
          end
        when "notifications/initialized" then { status: 202 }
        when "tools/call"
          request.headers["Mcp-Session-Id"] == "s1" ? { status: 404 } : { json: json_rpc(request.json["id"], { tools: [] }) }
        when "tools/list"
          expect(request.headers["Mcp-Session-Id"]).to eq("s1")
          expect(request.headers["MCP-Protocol-Version"]).to eq("2025-11-25")
          { json: json_rpc(request.json["id"], { tools: [] }) }
        end
      end
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                               http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake))
      faked.handshake(timeout: 5, cancelled: nil)
      expect(faked.era).to eq(:legacy)

      expect(faked.request("tools/call", { name: "x" }, timeout: 5)).to eq("tools" => [])
      expect(observed_era).to eq(:legacy)
    end

    it "raises an immediate expiration on same-thread re-entry during renewal" do
      fake = Samagotchi::Testing::FakeHttp.new
      faked = nil
      initialized = false
      fake.stub(:post, %r{/mcp}) do |request|
        case request.json["method"]
        when "server/discover" then { status: 405 }
        when "initialize"
          if initialized
            begin
              faked.request("tools/list", nil, timeout: 5)
            rescue errors::Unavailable => e
              expect(e.message).to eq("the session expired (404)")
            end
            { json: json_rpc(request.json["id"], { protocolVersion: "2025-11-25" }),
              headers: { "Mcp-Session-Id" => "s2" } }
          else
            initialized = true
            { json: json_rpc(request.json["id"], { protocolVersion: "2025-11-25" }),
              headers: { "Mcp-Session-Id" => "s1" } }
          end
        when "notifications/initialized" then { status: 202 }
        when "tools/call"
          request.headers["Mcp-Session-Id"] == "s1" ? { status: 404 } : { json: json_rpc(request.json["id"], { tools: [] }) }
        when "tools/list"
          request.headers["Mcp-Session-Id"] == "s1" ? { status: 404 } : { json: json_rpc(request.json["id"], { tools: [] }) }
        end
      end
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                               http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake))
      faked.handshake(timeout: 5, cancelled: nil)

      expect(faked.request("tools/call", { name: "x" }, timeout: 5)).to eq("tools" => [])
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
      # ctx.http's default cancel is a stopped turn's: the DELETE goes out all the same.
      stopped = Samagotchi::CancellationController.new.tap(&:cancel!)
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                                    http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake, cancel_lookup: -> { stopped }))
      faked.handshake(timeout: 5, cancelled: nil)

      expect(faked.close).to be_nil
      delete = fake.requests.last
      expect([delete.method, delete.headers["Mcp-Session-Id"], delete.headers["MCP-Protocol-Version"]]).to eq(%w[DELETE s1 2025-11-25])
      expect(faked.close).to be_nil
      expect(fake.requests.count { |r| r.method == "DELETE" }).to eq(1)
    end
  end

  describe "statuses" do
    it "says a 401 needs a token or sign-in, its status on the error, and doesn't try legacy" do
      server.enqueue("/mcp", status: 401, body: "")

      expect { client.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(client_class::Refused, "needs a token or sign-in (401)") { |e| expect(e.status).to eq(401) }
      expect(methods_sent).to eq(["server/discover"])
    end

    context "with a token" do
      let(:token) { client_class::StaticToken.new { "fake-token-value" } }

      it "sends it as a bearer token, and says a 401 refused it" do
        server.enqueue("/mcp", status: 401, body: "bad request: token", headers: { "Content-Type" => "text/plain" })

        expect { client.handshake(timeout: 5, cancelled: nil) }.to raise_error(errors::Unavailable, "refused the token (401)")
        expect(server.requests.last.header("authorization")).to eq("Bearer fake-token-value")
      end
    end

    it "sends nothing when the token's variable is unset" do
      unset = client_class.new(url, headers: {}, token: client_class::StaticToken.new { raise client_class::Refused, "GITHUB_MCP_TOKEN is not set" },
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

    it "words a redirect whose Location isn't a URL without it (it may be a signed URL)" do
      fake = Samagotchi::Testing::FakeHttp.new
      fake.stub(:post, %r{/mcp}, status: 302, headers: { "Location" => "http://[bad/x?k=QUERY-SECRET" })
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                                    http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: fake))

      # discover's 302 falls to legacy; initialize's is the error.
      expect { faked.handshake(timeout: 5, cancelled: nil) }
        .to raise_error(errors::Unavailable, "redirected (302): set url: to the new address")
      expect(fake.requests.size).to eq(2)
    end

    it "reads at most 64 KB of a JSON error body: past them it is a bare status, at once" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      big = %({"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"#{"x" * 70_000}"}})
      server.enqueue("/mcp", status: 500, sse: [big], headers: { "Content-Type" => "application/json" }, hold: true)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.request("tools/list", nil, timeout: 3) }.to raise_error(errors::Unavailable, "HTTP 500")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(1.5, below: 3)
    ensure
      server.release
    end

    context "with an authorization header of the config's own, in any case" do
      let(:headers) { { "authorization" => "Bearer HEADER-SECRET" } }

      it "says a 401 refused it" do
        server.enqueue("/mcp", status: 401, body: "")

        expect { client.handshake(timeout: 5, cancelled: nil) }.to raise_error(errors::Unavailable, "refused the token (401)")
      end
    end

    it "calls a server it can't reach Dead, naming host and port" do
      port = TCPServer.new("127.0.0.1", 0).then { |s| s.addr[1].tap { s.close } }
      gone = client_class.new("http://127.0.0.1:#{port}/mcp", headers: {}, token: client_class::StaticToken.new { nil }, http: http, log: ->(*) {})

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

    def elapsed_since(started) = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    def hold_renewal
      server.enqueue("/mcp", status: 405)
      legacy_answers(2, session: "s1")
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", status: 404)
      server.enqueue("/mcp", sse: [], hold: true)
      renewer = Thread.new do
        client.request("tools/call", { name: "expired" }, timeout: 10)
      rescue errors::Error => e
        e
      end
      SpecWaiting.wait_for("the renewal to be held", timeout: 10) { server.holding.positive? }
      renewer
    end

    it "keeps a second expired request within its timeout while renewal is held" do
      renewer = hold_renewal
      server.enqueue("/mcp", status: 404)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      error = nil
      waiter = Thread.new do
        client.request("tools/list", nil, timeout: 0.3)
      rescue errors::Error => e
        error = e
      end
      SpecWaiting.join!(waiter, "the timed-out request", timeout: 1)

      expect(waiter).not_to be_alive
      expect(error).to be_a(errors::Timeout)
      expect(error.message).to eq("tools/list timed out after 0.3s")
      expect(elapsed_since(started)).to be < time_bound(0.5, below: 0.8)
      server.release
      expect(renewer.value).to be_a(errors::Error)
    ensure
      server.release
      waiter&.join
      renewer&.join
    end

    it "cancels a second expired request waiting for renewal" do
      renewer = hold_renewal
      server.enqueue("/mcp", status: 404)
      stop = Samagotchi::CancellationController.new
      waiting_thread = nil
      waiting = Queue.new
      allow(client).to receive(:with_renewal).and_wrap_original do |original, *args, &block|
        waiting << true if Thread.current.equal?(waiting_thread)
        original.call(*args, &block)
      end
      error = nil
      start = Queue.new
      waiter = Thread.new do
        start.pop
        client.request("tools/list", nil, timeout: 5, cancelled: stop)
      rescue errors::Error => e
        error = e
      end
      waiting_thread = waiter
      start << true
      SpecWaiting.wait_for("the request to wait for renewal", timeout: 2) { !waiting.empty? }
      stop.cancel!
      SpecWaiting.join!(waiter, "the cancelled request", timeout: 1)

      expect(waiter).not_to be_alive
      expect(error).to be_a(errors::Cancelled)
      expect(error.message).to eq("tools/list was cancelled")
      server.release
      expect(renewer.value).to be_a(errors::Error)
    ensure
      server.release
      waiter&.join
      renewer&.join
    end

    it "holds the budget by the clock: a keep-alive just before its end doesn't buy another read" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: [": a\n\n", ": b\n\n"], delay: 0.8, hold: true)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.request("tools/list", nil, timeout: 1) }.to raise_error(errors::Timeout, "tools/list timed out after 1s")
      expect(elapsed_since(started)).to be < time_bound(1.4, below: 1.7) # not 0.8 s + another 1 s read
    ensure
      server.release
    end

    it "spends the call's budget on a re-handshake too, not a new one" do
      server.enqueue("/mcp", status: 405, body: "")
      legacy_answers(2, session: "s1")
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", status: 404, body: "")
      server.enqueue("/mcp", sse: [": wait\n\n", sse(json_rpc(4, { protocolVersion: "2025-11-25" }))], delay: 0.7,
                             headers: { "Mcp-Session-Id" => "s2" })
      server.enqueue("/mcp", status: 202, body: "")
      server.enqueue("/mcp", sse: [], hold: true)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { client.request("tools/list", nil, timeout: 1) }.to raise_error(errors::Timeout, "tools/list timed out after 1s")
      expect(elapsed_since(started)).to be < time_bound(1.4, below: 1.6) # not 0.7 s + a fresh 1 s
      expect(methods_sent.drop(3)).to eq(%w[tools/list initialize notifications/initialized tools/list])
    ensure
      server.release
    end

    it "gives notifications/initialized what is left of the handshake's budget, not a fixed 10 s" do
      fake = Samagotchi::Testing::FakeHttp.new
      fake.stub(:post, %r{/mcp}) do |request|
        case request.json["method"]
        when "server/discover" then { status: 404 }
        when "initialize" then { events: [JSON.generate(json_rpc(2, {}))] }
        else { status: 202 }
        end
      end
      timeouts = {}
      recording = Class.new(SimpleDelegator) do
        define_method(:stream) do |**args, &block|
          timeouts[JSON.parse(args[:body])["method"]] = args[:timeout]
          __getobj__.stream(**args, &block)
        end
      end
      faked = client_class.new(url, headers: {}, token: client_class::StaticToken.new { nil }, log: ->(*) {},
                                    http: Samagotchi::Plugin::Http.new(bundle: "mcp", transport: recording.new(fake)))
      faked.handshake(timeout: 0.5, cancelled: nil)

      expect(timeouts.keys).to eq(%w[server/discover initialize notifications/initialized])
      expect(timeouts.values).to all(be <= 0.5)
    end

    it "times out a quiet stream with the stdio wording" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: [], hold: true)

      expect { client.request("tools/list", nil, timeout: 0.3) }.to raise_error(errors::Timeout, "tools/list timed out after 0.3s")
    end

    # A Stop on another thread once the server holds the request.
    def stop_once_held
      Samagotchi::CancellationController.new.tap do |stop|
        Thread.new do
          SpecWaiting.wait_for("the request to be held", timeout: 10) { server.holding.positive? }
          stop.cancel!
        end
      end
    end

    it "stops a call on its controller's Stop, long before the timeout" do
      modern_discover
      client.handshake(timeout: 5, cancelled: nil)
      server.enqueue("/mcp", sse: [], hold: true)

      expect { client.request("tools/call", { name: "slow" }, timeout: 30, cancelled: stop_once_held) }
        .to raise_error(errors::Cancelled, "tools/call was cancelled")
    end

    it "stops the handshake on a Stop too, leaving no thread behind" do
      server.enqueue("/mcp", sse: [], hold: true)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      before = Thread.list
      stop = stop_once_held

      expect { client.handshake(timeout: 30, cancelled: stop) }.to raise_error(errors::Cancelled, "server/discover was cancelled")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 30)
      # The threads the call left, by identity: not the fake server's (WEBrick's
      # connection thread, held until the server stops, and its timeout watcher,
      # started lazily on a process's first request) nor Ruby's Timeout thread
      # (lazy too), and not the stopper, which ends on its own.
      eventually(timeout: 2) do
        expect((Thread.list - before).select(&:alive?).reject { |t| t.inspect.match?(%r{/webrick/|Timeout stdlib}) }).to be_empty
      end
    end
  end

  context "with a token and header values" do
    let(:token) { client_class::StaticToken.new { "fake-token-value" } }

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
