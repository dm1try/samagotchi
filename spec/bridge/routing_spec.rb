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
# wrong method or an unknown path gets, and that the body-size and browser
# checks answer before any route.
RSpec.describe Samagotchi::Bridge, "routing" do
  let(:state_dir) { Dir.mktmpdir("bridge-routing") }
  let(:engine) do
    Samagotchi::Engine.new(client: test_client,
                           kernel: test_kernel)
  end
  let(:handlers) do
    %i[handle_cancel handle_answer handle_dismiss_question handle_post_turn handle_command handle_exit_request
       handle_recap handle_relay handle_relay_status handle_state handle_stats handle_snapshot]
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
    @port = JSON.parse(File.read(sidecar))["port"]
  end

  after do
    @bridge.stop
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.remove_entry(state_dir)
  end

  # One raw request on its own connection: [status, headers (lowercased), parsed body].
  def request(method, target, headers: {}, body: nil)
    sock = TCPSocket.new("127.0.0.1", @port)
    head = "#{method} #{target} HTTP/1.1\r\nHost: 127.0.0.1:#{@port}\r\nConnection: close\r\n"
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
      %w[POST command] => "handle_command",
      %w[POST exit] => "handle_exit_request",
      %w[POST recap] => "handle_recap",
      %w[POST relay] => "handle_relay",
      ["POST", "relay/status"] => "handle_relay_status",
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
    table = { "POST" => %w[cancel answer question/dismiss turn command exit recap relay relay/status], "GET" => %w[state stats snapshot] }
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

  it "serves a GET stream with the cursor, the snapshot flag and the client id from the query" do
    _, _, body = request("GET", "/session/abc/stream?from_seq=7-1&snapshot=1&client_id=web%3At1")
    expect(body).to eq("handler" => "serve_sse", "sid" => "abc", "last_event_id" => "7-1", "snapshot" => true,
                       "client_id" => "web:t1")
    _, _, body = request("GET", "/session/abc/stream", headers: { "Last-Event-ID" => "3-1" })
    expect(body).to eq("handler" => "serve_sse", "sid" => "abc", "last_event_id" => "3-1", "snapshot" => false,
                       "client_id" => nil)
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

  it "answers a body over the limit with 413 before the browser check" do
    big = "x" * (described_class::MAX_BODY_BYTES + 1)
    status, headers, body = request("POST", "/session/abc/turn", headers: { "Origin" => "https://evil.example" }, body: big)
    expect([status, headers["connection"], body["error"]]).to eq([413, "close", "too_large"])
    expect(@bridge).not_to have_received(:handle_post_turn)
  end
end
