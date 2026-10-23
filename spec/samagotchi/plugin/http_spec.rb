# frozen_string_literal: true

require "spec_helper"
require "socket"
require "net/http"
require "samagotchi/plugin/context"
require "samagotchi/cancellation_controller"
require_relative "../../support/fake_provider_server"

# ctx.http (docs/plugins.md, "Calling services"): the real transport against
# FakeProviderServer (WEBrick), the way spec/llm/http_spec.rb runs.
RSpec.describe Samagotchi::Plugin::Http do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:cancel_lookup) { -> {} }
  let(:http) { described_class.new(bundle: "echo", cancel_lookup: -> { cancel_lookup.call }) }
  let(:url) { "#{server.root_url}/x" }

  after { server.stop }

  def closed_port
    socket = TCPServer.new("127.0.0.1", 0)
    socket.addr[1].tap { socket.close }
  end

  it "GETs and returns status, headers (lower-case, frozen) and the body" do
    server.enqueue("/x", body: "hello", headers: { "X-Thing" => "A" })

    res = http.get("#{url}?q=1", headers: { "Authorization" => "Bearer k" })

    expect(res.status).to eq(200)
    expect(res).to be_ok
    expect(res.body).to eq("hello")
    expect(res.body.encoding).to eq(Encoding::UTF_8)
    expect(res.headers).to include("x-thing" => "A")
    expect(res.headers).to be_frozen
    seen = server.requests.last
    expect(seen.method).to eq("GET")
    expect(seen.query_string).to eq("q=1")
    expect(seen.header("authorization")).to eq("Bearer k")
    expect(seen.header("user-agent")).to eq(Samagotchi::USER_AGENT)
  end

  it "gives the timeout to the connect, the write and the read" do
    server.enqueue("/x", body: "")
    options = nil
    allow(Net::HTTP).to receive(:start).and_wrap_original do |original, *args, **opts, &block|
      options = opts
      original.call(*args, **opts, &block)
    end

    http.get(url, timeout: 7)

    expect(options).to include(open_timeout: 7.0, read_timeout: 7.0, write_timeout: 7.0)
  end

  it "always sends chi's User-Agent, replacing the plugin's" do
    server.enqueue("/x", body: "")

    http.get(url, headers: { "User-Agent" => "mine" })

    expect(server.requests.last.header("user-agent")).to eq(Samagotchi::USER_AGENT)
  end

  it "POSTs a JSON body with JSON headers and reads the JSON answer" do
    server.enqueue("/x", json: { "answer" => 42 })

    res = http.post_json(url, { text: "héllo", n: [1, 2] })

    expect(res.json).to eq("answer" => 42)
    expect(res.json).to eq("answer" => 42) # parsed per call, a Data memoizes nothing
    seen = server.requests.last
    expect(seen.method).to eq("POST")
    expect(seen.json).to eq("text" => "héllo", "n" => [1, 2])
    expect(seen.header("content-type")).to eq("application/json")
    expect(seen.header("accept")).to eq("application/json")
  end

  it "lets a plugin's own Content-Type or Accept win over post_json's" do
    server.enqueue("/x", body: "")

    http.post_json(url, {}, headers: { "content-type" => "application/vnd.api+json" })

    expect(server.requests.last.header("content-type")).to eq("application/vnd.api+json")
  end

  it "sends a String body as is with request (PUT: WEBrick serves no DELETE or PATCH)" do
    server.enqueue("/x", body: "ok")

    res = http.request(:put, url, body: "raw", headers: { "Content-Type" => "text/plain" })

    expect(res.body).to eq("ok")
    expect(server.requests.last.method).to eq("PUT")
    expect(server.requests.last.body).to eq("raw")
    expect(server.requests.last.header("content-type")).to eq("text/plain")
  end

  it "hands every method upper-case to the transport, PATCH among them" do
    calls = []
    transport = ->(**call) { calls << call[:method] }
    client = described_class.new(bundle: "echo", transport: transport)

    %i[get post put patch delete head].each { |verb| client.request(verb, url) }
    client.request("Patch", url)

    expect(calls).to eq(%w[GET POST PUT PATCH DELETE HEAD PATCH])
    expect(Net::HTTP.const_get("Patch")).to be < Net::HTTPRequest
  end

  it "returns a 4xx and a 5xx instead of raising" do
    server.enqueue("/x", status: 404, body: "nope")
    server.enqueue("/x", status: 503, body: "down")

    expect(http.get(url)).to have_attributes(status: 404, body: "nope", ok?: false)
    expect(http.get(url)).to have_attributes(status: 503, ok?: false)
  end

  it "doesn't follow a redirect: the 3xx comes back with its location" do
    server.enqueue("/x", status: 302, headers: { "Location" => "/y" }, body: "")

    res = http.get(url)

    expect(res.status).to eq(302)
    expect(res.headers["location"]).to end_with("/y")
    expect(server.requests.size).to eq(1)
  end

  it "answers a HEAD with an empty String body" do
    server.enqueue("/x", body: "ignored")

    res = http.request(:head, url)

    expect(res.status).to eq(200)
    expect(res.body).to eq("")
    expect(res.body.encoding).to eq(Encoding::UTF_8)
  end

  it "leaves a body that isn't UTF-8 binary, and tags a valid one UTF-8" do
    server.enqueue("/x", body: "caf\xE9".b)
    server.enqueue("/x", body: "café".b)

    binary = http.get(url).body
    text = http.get(url).body

    expect(binary.encoding).to eq(Encoding::BINARY)
    expect(binary.bytes).to eq("caf\xE9".b.bytes)
    expect(text.encoding).to eq(Encoding::UTF_8)
    expect(text).to eq("café")
  end

  describe "#json" do
    it "raises HttpError on a body that isn't JSON, without quoting it" do
      server.enqueue("/x", body: "<html>SECRET page</html>")

      res = http.get(url)

      expect { res.json }.to raise_error(Samagotchi::Plugin::HttpError, /not JSON: status 200/) { |e|
        expect(e.message).not_to include("SECRET")
      }
    end

    it "raises HttpError on an empty body" do
      server.enqueue("/x", body: "")

      expect { http.get(url).json }.to raise_error(Samagotchi::Plugin::HttpError)
    end
  end

  describe "errors" do
    it "maps a refused connection to HttpError saying what and where, with the cause kept" do
      port = closed_port

      expect { http.get("http://127.0.0.1:#{port}/x?secret=1") }
        .to raise_error(Samagotchi::Plugin::HttpError, "GET 127.0.0.1:#{port}: connection refused") { |e|
          expect(e).not_to be_a(Samagotchi::Plugin::HttpCancelled)
          expect(e.cause).to be_a(Errno::ECONNREFUSED)
        }
    end

    it "maps a name that doesn't resolve to HttpError" do
      expect { http.get("http://no-such-host.invalid/x", timeout: 3) }.to raise_error(Samagotchi::Plugin::HttpError)
    end

    it "times out on a read as HttpError" do
      server.enqueue("/x", sse: [], hold: true)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { http.get(url, timeout: 0.3) }.to raise_error(Samagotchi::Plugin::HttpError, /timed out/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end

    it "maps a malformed response to HttpError, with no raw Net:: error escaping" do
      raw = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        client = raw.accept
        client.readpartial(4096)
        client.write("not http at all\r\n\r\n")
        client.close
      end

      expect { http.get("http://127.0.0.1:#{raw.addr[1]}/x") }.to raise_error(Samagotchi::Plugin::HttpError, /malformed response/)
    ensure
      thread&.kill
      raw&.close
    end

    it "maps a bad gzip body to HttpError" do
      server.enqueue("/x", body: "this is not gzip", headers: { "Content-Encoding" => "gzip" })

      expect { http.get(url) }.to raise_error(Samagotchi::Plugin::HttpError, /bad compressed body/)
    end

    it "raises chi's own bug as it is, logged with its backtrace, instead of a network HttpError" do
      require "samagotchi/plugin/http_transport"
      allow_any_instance_of(Samagotchi::LLM::HTTP).to receive(:fetch).and_raise(NoMethodError, "undefined method 'x'")
      allow(Samagotchi::Log).to receive(:exception)

      expect { http.get(url) }.to raise_error(NoMethodError, /undefined method/)
      expect(Samagotchi::Log).to have_received(:exception)
        .with(:plugins, "http_transport_failed", an_instance_of(NoMethodError), bundle: "echo")
    end

    it "maps a provider error from chi's HTTP layer to HttpError" do
      require "samagotchi/plugin/http_transport"
      allow_any_instance_of(Samagotchi::LLM::HTTP).to receive(:fetch)
        .and_raise(Samagotchi::LLM::RetryExhausted.new(attempts: 1, last_error: EOFError.new, label: "plugin:echo"))

      expect { http.get(url) }.to raise_error(Samagotchi::Plugin::HttpError, /failed \(Samagotchi::LLM::RetryExhausted\)/)
    end
  end

  describe "cancel" do
    it "raises HttpCancelled for an already-cancelled controller, sending nothing" do
      cancel = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:manual) }

      expect { http.get(url, cancel: cancel) }.to raise_error(Samagotchi::Plugin::HttpCancelled)
      expect(server.requests).to be_empty
    end

    it "stops a call mid-read when the controller is cancelled, long before its timeout" do
      server.enqueue("/x", sse: [], hold: true)
      cancel = Samagotchi::CancellationController.new
      requester = Thread.current
      canceller = Thread.new do
        # Mid-read: the server has the request and the call is blocked on its answer.
        SpecWaiting.wait_for("the held request") { server.requests.any? { |request| request.path == "/x" } }
        SpecWaiting.wait_for("the call to wait for its answer") { requester.status == "sleep" }
      ensure
        cancel.cancel!(:manual)
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { http.get(url, timeout: 30, cancel: cancel) }.to raise_error(Samagotchi::Plugin::HttpCancelled, /cancelled/)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    ensure
      # Bounded, but no raise here: it would hide the example's own failure.
      canceller&.join(5)
    end

    it "uses the default lookup's controller when no cancel: is given, and cancel: wins over it" do
      stopped = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:manual) }
      server.enqueue("/x", body: "ok")
      defaulted = described_class.new(bundle: "echo", cancel_lookup: -> { stopped })

      expect { defaulted.get(url) }.to raise_error(Samagotchi::Plugin::HttpCancelled)
      expect(defaulted.get(url, cancel: Samagotchi::CancellationController.new).body).to eq("ok")
    end
  end

  describe "arguments" do
    it "raises ArgumentError before any request for a bad scheme, URL, method, timeout, header or body" do
      expect { http.get("ftp://example.com/x") }.to raise_error(ArgumentError, /http/)
      expect { http.get("file:///etc/passwd") }.to raise_error(ArgumentError)
      expect { http.get("/just/a/path") }.to raise_error(ArgumentError)
      expect { http.get("http://exa mple.com") }.to raise_error(ArgumentError, /not a URL/)
      expect { http.get(nil) }.to raise_error(ArgumentError)
      expect { http.request(:trace, url) }.to raise_error(ArgumentError, /unknown HTTP method/)
      expect { http.get(url, timeout: 0) }.to raise_error(ArgumentError, /timeout/)
      expect { http.get(url, timeout: "5") }.to raise_error(ArgumentError, /timeout/)
      expect { http.get(url, headers: [%w[a b]]) }.to raise_error(ArgumentError, /headers/)
      expect { http.request(:post, url, body: { a: 1 }) }.to raise_error(ArgumentError, /String/)
      expect { http.post_json(url, Float::NAN) }.to raise_error(ArgumentError, /JSON/)
      expect(server.requests).to be_empty
    end

    it "quotes a bad URL without its query, fragment or user info" do
      bad = ["ftp://user:pw@example.com/x?key=SECRET#frag", "/just/a/path?key=SECRET", "http://exa mple.com/?key=SECRET",
             "http://user:pw@exa mple.com/x?key=SECRET"]

      bad.each do |url|
        expect { http.get(url) }.to raise_error(ArgumentError) { |e|
          expect(e.message).not_to match(/SECRET|pw|frag/)
        }
      end
      expect { http.get("ftp://example.com/x?key=SECRET") }.to raise_error(ArgumentError, %r{"ftp://example.com/x"})
    end

    it "accepts a URI" do
      server.enqueue("/x", body: "ok")

      expect(http.get(URI(url)).body).to eq("ok")
    end
  end

  describe "the log line" do
    it "is one INFO http line with bundle and purpose, the URL without query, and no headers or body" do
      server.enqueue("/x", body: "RESPONSE-BODY")
      lines = []
      allow(Samagotchi::Log).to receive(:public_send).and_wrap_original do |original, level, tag, event, **fields|
        lines << [level, tag, event, fields]
        original.call(level, tag, event, **fields)
      end

      http.post_json("#{url}?token=hunter2", { secret: "REQUEST-BODY" }, headers: { "Authorization" => "Bearer hunter2" })

      http_lines = lines.select { |_, tag, *| tag == :http }
      expect(http_lines.size).to eq(1)
      level, _tag, event, fields = http_lines.first
      expect([level, event]).to eq([:info, "fetch"])
      expect(fields).to include(bundle: "echo", purpose: "plugin", method: "POST", url: url, status: 200)
      expect(fields.inspect).not_to match(/hunter2|REQUEST-BODY|RESPONSE-BODY|Authorization/)
    end

    it "is an ERROR line when the call fails, still without the query" do
      port = closed_port
      lines = []
      allow(Samagotchi::Log).to receive(:public_send).and_wrap_original do |original, level, tag, event, **fields|
        lines << [level, tag, event, fields]
        original.call(level, tag, event, **fields)
      end

      expect { http.get("http://127.0.0.1:#{port}/x?token=hunter2") }.to raise_error(Samagotchi::Plugin::HttpError)

      level, _tag, event, fields = lines.find { |_, tag, *| tag == :http }
      expect([level, event]).to eq([:error, "failed"])
      expect(fields).to include(bundle: "echo", purpose: "plugin")
      expect(fields.inspect).not_to include("hunter2")
    end
  end

  describe "constants" do
    it "resolve through Plugin::Context's autoloads before any call" do
      expect(Samagotchi::Plugin::HttpError).to be < StandardError
      expect(Samagotchi::Plugin::HttpCancelled).to be < Samagotchi::Plugin::HttpError
      expect(Samagotchi::Plugin::Http::Response.new(status: 204, headers: {}.freeze, body: "")).to be_ok
    end
  end
end
