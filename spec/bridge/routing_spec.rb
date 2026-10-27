# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"

# The Bridge's route table: which handler every method + path reaches, what a
# wrong method or an unknown path gets, and that the body-size, browser and secret
# checks answer before any route.
RSpec.describe Samagotchi::Bridge, "routing" do
  let(:state_dir) { Dir.mktmpdir("bridge-routing") }
  let(:engine) do
    Samagotchi::Engine.new(client: test_client,
                           kernel: test_kernel)
  end
  let(:handlers) do
    %i[handle_cancel handle_answer handle_dismiss_question handle_post_turn handle_dequeue_turn handle_command handle_exit_request
       handle_recap handle_relay handle_relay_status handle_task_stop handle_state handle_stats handle_snapshot]
  end

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    @bridge = described_class.new(engine: engine, state_dir: state_dir, session_id: "s1", heartbeat_interval: 0.2)
    handlers.each do |name|
      allow(@bridge).to receive(name) { |sid, *| [{ "X-Route" => name.to_s }, 200, { handler: name.to_s, sid: sid }] }
    end
    allow(@bridge).to receive(:serve_sse) do |io, sid, **kw|
      @bridge.send(:write_json, io, 200, { "Connection" => "close" }, { handler: "serve_sse", sid: sid, **kw })
    end
    @bridge.start
    sidecar = File.join(Samagotchi::Session.session_dir("s1", state_dir: state_dir), "bridge.json")
    @port, @secret = JSON.parse(File.read(sidecar)).values_at("port", "secret")
  end

  after do
    @bridge.stop
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.remove_entry(state_dir)
  end

  # One raw request on its own connection: [status, headers (lowercased), parsed body]. It names the
  # Bridge's secret, as chi's clients do, unless +secret+ is another one (nil: none).
  def request(method, target, headers: {}, body: nil, secret: @secret)
    sock = TCPSocket.new("127.0.0.1", @port)
    head = "#{method} #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nConnection: close\r\n"
    head << "X-Chi-Bridge: #{secret}\r\n" if secret
    headers.each { |k, v| head << "#{k}: #{v}\r\n" }
    head << "Content-Length: #{body.bytesize}\r\n" if body
    sock.write("#{head}\r\n#{body}")
    raw = sock.read
    sock.close
    status_line, *lines = raw.split("\r\n\r\n", 2).first.split("\r\n")
    heads = lines.to_h { |l| k, v = l.split(":", 2); [k.downcase, v.strip] }
    [status_line.split(" ")[1].to_i, heads, JSON.parse(raw.split("\r\n\r\n", 2).last)]
  end

  it "sends every route to its handler with the session id and the body" do
    table = {
      %w[POST cancel] => "handle_cancel",
      %w[POST answer] => "handle_answer",
      ["POST", "question/dismiss"] => "handle_dismiss_question",
      %w[POST turn] => "handle_post_turn",
      ["POST", "turn/dequeue"] => "handle_dequeue_turn",
      %w[POST command] => "handle_command",
      %w[POST exit] => "handle_exit_request",
      %w[POST recap] => "handle_recap",
      %w[POST relay] => "handle_relay",
      ["POST", "relay/status"] => "handle_relay_status",
      ["POST", "tasks/stop"] => "handle_task_stop",
      %w[GET state] => "handle_state",
      %w[GET stats] => "handle_stats",
      %w[GET snapshot] => "handle_snapshot"
    }
    table.each do |(method, action), handler|
      status, headers, body = request(method, "/session/s1/#{action}", body: method == "POST" ? '{"x":1}' : nil)
      expect([status, headers["x-route"], body]).to eq([200, handler, { "handler" => handler, "sid" => "s1" }]),
                                                    "#{method} #{action}"
    end
    expect(@bridge).to have_received(:handle_post_turn).with("s1", '{"x":1}')
    expect(@bridge).to have_received(:handle_cancel).with("s1", '{"x":1}')
    expect(request("get", "/session/s1/state")[2]).to eq("handler" => "handle_state", "sid" => "s1")
  end

  it "answers another session's id with 404 before any handler, and a handler that raises with 500" do
    table = { "POST" => %w[cancel answer question/dismiss turn turn/dequeue command exit recap relay relay/status tasks/stop], "GET" => %w[state stats snapshot] }
    table.each do |method, actions|
      actions.each do |action|
        status, _, body = request(method, "/session/other/#{action}", body: method == "POST" ? "{}" : nil)
        expect([status, body]).to eq([404, { "error" => "unknown_session" }]), "#{method} #{action}"
      end
    end
    handlers.each { |name| expect(@bridge).not_to have_received(name) }

    allow(@bridge).to receive(:handle_stats).and_raise(RuntimeError, "boom")
    expect(request("GET", "/session/s1/stats").values_at(0, 2)).to eq([500, { "error" => "bridge_error", "detail" => "boom" }])
  end

  it "serves a GET stream with the cursor, the snapshot flag, the client id and the raw flag from the query" do
    _, _, body = request("GET", "/session/abc/stream?from_seq=7-1&snapshot=1&client_id=web%3At1")
    expect(body).to eq("handler" => "serve_sse", "sid" => "abc", "last_event_id" => "7-1", "snapshot" => true,
                       "client_id" => "web:t1", "raw" => false)
    _, _, body = request("GET", "/session/abc/stream?raw=1", headers: { "Last-Event-ID" => "3-1" })
    expect(body).to eq("handler" => "serve_sse", "sid" => "abc", "last_event_id" => "3-1", "snapshot" => false,
                       "client_id" => nil, "raw" => true)
  end

  it "answers a wrong method or an unknown path with 404, Allow: GET, POST" do
    [
      ["GET", "/session/abc/turn"], ["POST", "/session/abc/stream"], ["POST", "/session/abc/state"],
      ["GET", "/session/abc/question/dismiss"], ["PUT", "/session/abc/cancel"], ["DELETE", "/session/abc/state"],
      ["OPTIONS", "/session/abc/turn"],
      ["GET", "/session/abc/nope"], ["GET", "/session/abc"], ["GET", "/session/a/b/state"], ["GET", "/nope"],
      ["POST", "/session/abc/question"], ["GET", "/session//state"]
    ].each do |method, path|
      status, headers, body = request(method, path, body: method == "GET" ? nil : "{}")
      expect([status, headers["allow"], body]).to eq([404, "GET, POST", { "error" => "not_found", "path" => path }]),
                                                  "#{method} #{path}"
    end
    handlers.each { |name| expect(@bridge).not_to have_received(name) }
  end

  it "refuses a browser before any route, unknown paths included" do
    [
      ["POST", "/session/abc/turn", { "Origin" => "https://evil.example" }],
      ["GET", "/session/abc/stream", { "Sec-Fetch-Site" => "same-origin" }],
      ["GET", "/nope", { "Origin" => "null" }],
      ["GET", "/session/abc/state", { "Host" => "evil.example" }]
    ].each do |method, path, headers|
      expect(request(method, path, headers: headers, body: method == "POST" ? "{}" : nil).values_at(0, 2))
        .to eq([403, { "error" => "cross_origin", "detail" => "the bridge answers chi's own clients only" }]), path
    end
    handlers.each { |name| expect(@bridge).not_to have_received(name) }
    expect(@bridge).not_to have_received(:serve_sse)
  end

  it "refuses a request through a proxy (any trace a proxy adds, an underscore twin too) before any route" do
    [
      ["POST", "/session/abc/turn", { "X-Forwarded-For" => "203.0.113.9" }],
      ["GET", "/session/abc/state", { "X_Forwarded_For" => "203.0.113.9" }],
      ["GET", "/session/abc/snapshot", { "X-Forwarded-Email" => "alex@pod.test" }],
      ["GET", "/session/abc/stream", { "Forwarded" => "for=203.0.113.9" }],
      ["GET", "/session/abc/state", { "X-Real-IP" => "203.0.113.9" }],
      ["GET", "/session/abc/state", { "X-Auth-Request-Email" => "a@b" }],
      ["GET", "/session/abc/state", { "Cf-Connecting-Ip" => "203.0.113.9" }],
      ["GET", "/nope", { "Tailscale-User-Login" => "a@b" }]
    ].each do |method, path, headers|
      status, _, body = request(method, path, headers: headers, body: method == "POST" ? "{}" : nil)
      expect([status, body["error"]]).to eq([403, "proxied"]), headers.keys.first
    end
    handlers.each { |name| expect(@bridge).not_to have_received(name) }
    expect(@bridge).not_to have_received(:serve_sse)
  end

  it "logs the proxied refusal at most once a minute (a scan through the forward would fill the log)" do
    allow(Samagotchi::Log).to receive(:warn)
    3.times { request("GET", "/session/abc/state", headers: { "X-Forwarded-For" => "203.0.113.9" }) }
    expect(Samagotchi::Log).to have_received(:warn).with(:bridge, "proxied_refused", anything).once
  end

  it "answers chi's own requests, which carry no proxy trace (Last-Event-ID, Authorization, Content-Type)" do
    _, _, body = request("GET", "/session/abc/stream", headers: { "Last-Event-ID" => "3-1" })
    expect(body["handler"]).to eq("serve_sse")
  end

  describe "the Bridge's secret" do
    let(:refused) { [403, { "error" => "bridge_secret", "detail" => Samagotchi::BridgeSecret.refused("s1") }] }
    # One request of each kind: the stream, a read, a write, a read-only POST, an unknown path.
    let(:route_classes) do
      [["GET", "/session/s1/stream"], ["GET", "/session/s1/state"], ["GET", "/session/s1/stats"],
       ["POST", "/session/s1/turn"], ["POST", "/session/s1/exit"], ["POST", "/session/s1/relay/status"],
       ["GET", "/session/other/state"], ["GET", "/nope"]]
    end

    it "is in the 0600 sidecar: 64 hex characters (32 random bytes), another for every Bridge" do
      path = File.join(Samagotchi::Session.session_dir("s1", state_dir: state_dir), "bridge.json")
      expect(@secret).to match(/\A\h{64}\z/)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      other = described_class.new(engine: engine, state_dir: state_dir, session_id: "s2")
      expect(other.instance_variable_get(:@secret)).not_to eq(@secret)
    end

    it "is asked of every request before any route: none, an empty one, another one, a cut one or its upper case are refused" do
      [nil, "", "0" * 64, @secret[0, 63], "#{@secret}0", @secret.upcase].each do |secret|
        route_classes.each do |method, path|
          answer = request(method, path, secret: secret, body: method == "POST" ? '{"x":1}' : nil)
          expect(answer.values_at(0, 2)).to eq(refused), "#{method} #{path} with #{secret.inspect}"
        end
      end
      handlers.each { |name| expect(@bridge).not_to have_received(name) }
      expect(@bridge).not_to have_received(:serve_sse)
    end

    it "lets the request with it through to its route" do
      expect(request("GET", "/session/s1/state").values_at(0, 2)).to eq([200, { "handler" => "handle_state", "sid" => "s1" }])
      expect(request("GET", "/session/s1/stream")[2]["handler"]).to eq("serve_sse")
    end

    it "comes after the browser and proxy checks, which say more" do
      expect(request("GET", "/session/s1/state", headers: { "Origin" => "null" }, secret: nil)[2]["error"]).to eq("cross_origin")
      expect(request("GET", "/session/s1/state", headers: { "X-Forwarded-For" => "203.0.113.9" }, secret: nil)[2]["error"])
        .to eq("proxied")
    end

    it "logs a refusal at most once a minute, with the path and never a header's value" do
      allow(Samagotchi::Log).to receive(:warn)
      3.times { request("GET", "/session/s1/state", secret: "f" * 64) }
      expect(Samagotchi::Log).to have_received(:warn).with(:bridge, "secret_refused", { path: "/session/s1/state" }).once
    end
  end

  it "answers a body over the limit with 413 before the browser check" do
    big = "x" * (described_class::MAX_BODY_BYTES + 1)
    status, headers, body = request("POST", "/session/abc/turn", headers: { "Origin" => "https://evil.example" }, body: big)
    expect([status, headers["connection"], body["error"]]).to eq([413, "close", "too_large"])
    expect(@bridge).not_to have_received(:handle_post_turn)
  end
end
