# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "stringio"
require "rack/mock"
require "rack/request"

require "samagotchi/web/app"
require "samagotchi/session"

# Emulates SessionManager#read_responses over an in-memory response list,
# optionally filtering by mtime threshold using a parallel +times+ array.
class FakeResponsesManager
  attr_accessor :responses, :times
  attr_reader :spawn_calls

  def initialize(responses: [], times: nil)
    @responses = responses
    @times = times
    @spawn_calls = []
  end

  def read_responses(_session_id, since_time: nil, state_dir: nil)
    return @responses if since_time.nil? || @times.nil?

    @responses.each_with_index.select { |_, i| @times[i] > since_time }.map(&:first)
  end

  def spawn_session(prompt:, state_dir: nil, **kw)
    @spawn_calls << { prompt: prompt, state_dir: state_dir, extra: kw }
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
      s.last_prompt = prompt
    end
  end

  def list_sessions(state_dir: nil, sort: nil, order: nil, limit: nil, offset: 0)
    []
  end

  def retention_sweep_if_due(state_dir: nil)
    nil
  end

  def resume_session(_id, state_dir: nil); nil; end
  def write_turn_input(_id, prompt:, state_dir: nil); true; end
  def stop_session(_id, state_dir: nil); nil; end
  def wait_for_session(_id, timeout: 30, state_dir: nil); nil; end
end

# Loader that pretends a session always exists, so stream/show specs don't need
# real session.json files on disk. Exposes a persisted assistant exchange so
# messages_for_display has something to render.
class StubSessionLoader
  class << self
    def load(_id, state_dir: nil)
      s = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      s.messages = [
        { role: "user", content: "hello" },
        { role: "assistant", content: "hi there" }
      ]
      s
    end

    def session_dir(id, state_dir: nil)
      File.join(state_dir.to_s, id)
    end
  end
end

RSpec.describe Samagotchi::Web::App do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # bridge_wait_timeout: 0 — no real worker is spawned in these specs, so the
  # create handler must not wait for a bridge sidecar.
  def build_app(manager: nil, state_dir: nil)
    manager ||= FakeResponsesManager.new
    described_class.new(manager: manager, state_dir: state_dir, session_class: StubSessionLoader, bridge_wait_timeout: 0)
  end

  def env_for(path, method: "GET", body: nil, headers: {})
    Rack::MockRequest.env_for(
      path,
      "HTTP_HOST" => "127.0.0.1",
      method: method,
      input: body,
      **headers
    )
  end


  describe "GET /api/sessions/:id/stream" do
    it "returns a typed 503 not_live when no live bridge sidecar exists" do
      app = build_app(state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1/stream"))

      expect(status).to eq(503)
      expect(JSON.parse(body.first)).to include("error" => "not_live")
    end

    it "proxies to the live bridge and forwards the client query string" do
      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(9_999)
      status, headers, body = app.call(env_for("/api/sessions/s1/stream?from_seq=3"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/event-stream")
      expect(body).to be_a(described_class::ProxyStreamBody)
      expect(body.instance_variable_get(:@query)).to eq("?from_seq=3")
    end

    it "forwards the Last-Event-ID header through to the bridge" do
      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(9_999)
      _status, _headers, body = app.call(
        env_for("/api/sessions/s1/stream?from_seq=3", headers: { "HTTP_LAST_EVENT_ID" => "7" })
      )

      expect(body.instance_variable_get(:@headers)["HTTP_LAST_EVENT_ID"]).to eq("7")
    end

    it "honors rack.hijack? by returning a lambda that pipes bridge frames straight to the socket" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      accept_thread = Thread.new do
        conn = server.accept
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nid: 1\nevent: generation_chunk\ndata: {\"content\":\"one\"}\r\n\r\n")
        sleep(0.3)
        conn.close
      end
      accept_thread.report_on_exception = false

      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(port)
      status, headers, body = app.call(
        env_for("/api/sessions/s1/stream?from_seq=0", headers: { "rack.hijack?" => true })
      )

      expect(status).to eq(200)
      expect(body).to eq([])
      hijack = headers["rack.hijack"]
      expect(hijack).to respond_to(:call)

      out = StringIO.new
      hijack.call(out)
      server.close
      accept_thread.join(1)

      expect(out.string).to include("id: 1")
      expect(out.string).to include("event: generation_chunk")
      expect(out.string).to include(%q{"content":"one"})
      expect(out.string).not_to include("HTTP/1.1") # handler owns the status line
    end
  end

  describe "GET /api/sessions/:id" do
    it "includes last_event_seq = nil when no bridge is live" do
      manager = FakeResponsesManager.new(responses: %w[one two three])
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload["last_event_seq"]).to be_nil
      expect(payload["messages"].map { |m| m["content"] }).to eq(%w[hello hi\ there])
    end

    it "uses the bridge event_seq when a live bridge reports it" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_event_seq).and_return(12)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      expect(JSON.parse(body.first)["last_event_seq"]).to eq(12)
    end
  end

  describe "POST /api/sessions (worker spawn)" do
    it "spawns the worker (bridge is always on) and reports the session" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager)
      status, _headers, body = app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(201)
      expect(manager.spawn_calls.last[:prompt]).to eq("hi")
      expect(JSON.parse(body.first)).to have_key("id")
    end

    it "reports the bridge port once the worker bridge comes up" do
      manager = FakeResponsesManager.new
      app = described_class.new(manager: manager, session_class: StubSessionLoader, bridge_wait_timeout: 5)
      allow(app).to receive(:bridge_sidecar_port).and_return(nil, nil, 4_321)
      status, _headers, body = app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(201)
      expect(JSON.parse(body.first)["bridge_port"]).to eq(4_321)
    end

    it "reports a null bridge_port when the bridge is not up by the deadline" do
      manager = FakeResponsesManager.new
      app = described_class.new(manager: manager, session_class: StubSessionLoader, bridge_wait_timeout: 0.3)
      allow(app).to receive(:bridge_sidecar_port).and_return(nil)
      status, _headers, body = app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(201)
      expect(JSON.parse(body.first)["bridge_port"]).to be_nil
    end
  end

  describe "GET /" do
    it "serves index.html with hard no-cache headers and no polling code" do
      app = build_app(manager: FakeResponsesManager.new)
      status, headers, body = app.call(env_for("/"))

      expect(status).to eq(200)
      expect(headers["Cache-Control"]).to eq("no-store, no-cache, must-revalidate, max-age=0")
      expect(headers["Pragma"]).to eq("no-cache")
      expect(headers["Expires"]).to eq("0")
      expect(body.first).not_to include("startPoll")
      expect(body.first).to include("from_seq")
    end
  end

  describe "bridge_get_json" do
    it "returns nil when no live bridge sidecar is present" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      expect(app.send(:bridge_get_json, "does-not-exist", "state")).to be_nil
    end
  end

  describe "ProxyStreamBody" do
    # Capture the raw request a ProxyStreamBody issues against the upstream bridge.
    def capture_bridge_request(headers:, query: "")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      proxy = described_class::ProxyStreamBody.new(
        host: "127.0.0.1", port: port, session_id: "s1", query: query, headers: headers
      )
      request = nil
      t = Thread.new do
        conn = server.accept
        request = conn.readpartial(16_384)
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n")
        conn.close
      end
      t.report_on_exception = false
      Thread.new { proxy.each { |chunk| chunk } }
      deadline = mono + 2.0
      sleep(0.005) while request.nil? && mono < deadline
      server.close
      t.join(0.5)
      expect(request).not_to be_nil, "ProxyStreamBody never reached the bridge"
      request
    end

    it "forwards the Last-Event-ID header so the bridge resumes from the browser cursor" do
      raw = capture_bridge_request(headers: { "HTTP_LAST_EVENT_ID" => "7" }, query: "?from_seq=0")
      expect(raw).to include("Last-Event-ID: 7\r\n")
      expect(raw).to include("GET /session/s1/stream?from_seq=0 HTTP/1.1")
    end

    it "omits the header when the client sent no Last-Event-ID" do
      raw = capture_bridge_request(headers: {})
      expect(raw).not_to include("Last-Event-ID")
      expect(raw).to include("GET /session/s1/stream HTTP/1.1")
    end
  end
end