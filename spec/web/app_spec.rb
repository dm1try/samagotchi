# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
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

  def spawn_session(prompt:, state_dir: nil, bridge: false, **kw)
    @spawn_calls << { prompt: prompt, state_dir: state_dir, bridge: bridge, extra: kw }
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
  def write_cancel_flag(_id, reason: "user", state_dir: nil); true; end
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

  def build_app(manager: nil, state_dir: nil)
    manager ||= FakeResponsesManager.new
    described_class.new(manager: manager, state_dir: state_dir, session_class: StubSessionLoader)
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

  def parse_sse(frames)
    frames.map do |f|
      id = f[/^id: (.*)$/, 1]
      event = f[/^event: (.*)$/, 1]
      data_line = f[/^data: (.*)$/m, 1]
      { id: id, event: event, data: data_line ? JSON.parse(data_line) : nil }
    end
  end

  # Run a StreamBody#each and collect frames until +count+ arrive. Raises
  # StopIteration from the block which StreamBody's rescue-er swallows and
  # turns into a clean end-of-each; the thread is killed after the timeout.
  def frames_up_to(body, count:, timeout: 2.0)
    frames = []
    t = Thread.new do
      body.each do |f|
        frames << f
        raise StopIteration if frames.size >= count
      end
    rescue StandardError
      nil
    end
    t.report_on_exception = false
    deadline = mono + timeout
    sleep(0.005) while frames.size < count && mono < deadline
    t.kill if t.alive?
    t.join(0.2)
    frames
  end

  def stream_body(manager, cursor: nil, since: nil, poll: 0.05)
    described_class::StreamBody.new(
      session_id: "s1",
      manager: manager,
      state_dir: nil,
      heartbeat_interval: 60,
      poll_interval: poll,
      cursor: cursor,
      since_time: since
    )
  end

  describe "StreamBody" do
    it "emits every chunk with a stable, monotonic 1-based seq and id" do
      manager = FakeResponsesManager.new(responses: ["one", "two", "three"])
      events = parse_sse(frames_up_to(stream_body(manager, cursor: 0), count: 3))

      expect(events.map { |e| e[:id] }).to eq(%w[1 2 3])
      expect(events.map { |e| e[:data]["content"] }).to eq(%w[one two three])
      expect(events.map { |e| e[:event] }).to eq(%w[history history history])
    end

    it "skips chunks at or below the reconnect cursor" do
      manager = FakeResponsesManager.new(responses: %w[one two three four])
      events = parse_sse(frames_up_to(stream_body(manager, cursor: 2), count: 2))

      expect(events.map { |e| e[:id] }).to eq(%w[3 4])
    end

    it "emits nothing when the cursor is at/above the current chunk count" do
      manager = FakeResponsesManager.new(responses: %w[one two three])
      frames = frames_up_to(stream_body(manager, cursor: 5), count: 1, timeout: 0.4)

      expect(frames).to be_empty
    end

    it "does not reset the seq when new chunks are appended mid-connection" do
      manager = FakeResponsesManager.new(responses: %w[one two])
      frames = []
      t = Thread.new do
        stream_body(manager, cursor: 0).each do |f|
          frames << f
          raise StopIteration if frames.size >= 4
        end
      rescue StandardError
        nil
      end
      t.report_on_exception = false
      deadline = mono + 2.0
      sleep(0.005) while frames.size < 2 && mono < deadline
      manager.responses.concat(%w[three four])
      sleep(0.005) while frames.size < 4 && mono < deadline
      t.kill if t.alive?
      t.join(0.2)

      events = parse_sse(frames)
      expect(events.map { |e| e[:id] }).to eq(%w[1 2 3 4])
      expect(events.map { |e| e[:data]["content"] }).to eq(%w[one two three four])
    end

    it "honors the legacy ?since= timestamp (skips chunks older than the threshold)" do
      t0 = Time.now - 3600
      t1 = Time.now
      manager = FakeResponsesManager.new(
        responses: %w[old old2 new],
        times: [t0, t0, t1]
      )
      events = parse_sse(frames_up_to(stream_body(manager, since: Time.now - 1800), count: 1))

      expect(events.length).to eq(1)
      expect(events.first[:id]).to eq("3")
      expect(events.first[:data]["content"]).to eq("new")
    end

    it "strips empty/chunk bodies out of the seq numbering entirely" do
      manager = FakeResponsesManager.new(responses: ["a", "   ", "b"])
      events = parse_sse(frames_up_to(stream_body(manager, cursor: 0), count: 2))

      expect(events.map { |e| e[:id] }).to eq(%w[1 2])
      expect(events.map { |e| e[:data]["content"] }).to eq(%w[a b])
    end
  end

  describe "GET /api/sessions/:id/stream" do
    it "serves StreamBody (no bridge) and wires ?from_seq=<int> as the cursor" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      status, headers, body = app.call(env_for("/api/sessions/s1/stream?from_seq=3"))

      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/event-stream")
      expect(body).to be_a(described_class::StreamBody)
      expect(body.instance_variable_get(:@cursor)).to eq(3)
      expect(body.instance_variable_get(:@since_time)).to be_nil
    end

    it "prefers the Last-Event-ID header as the reconnect cursor" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/stream?from_seq=3", headers: { "HTTP_LAST_EVENT_ID" => "7" })
      )

      expect(status).to eq(200)
      expect(body.instance_variable_get(:@cursor)).to eq(7)
    end

    it "falls through to legacy ?since= (timestamp) when no int cursor is given" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      _status, _headers, body = app.call(
        env_for("/api/sessions/s1/stream?since=2020-01-01T00:00:00Z")
      )

      expect(body.instance_variable_get(:@cursor)).to be_nil
      expect(body.instance_variable_get(:@since_time)).to be_a(Time)
    end

    it "resolves a non-integer cursor/garbage into no cursor" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      _status, _headers, body = app.call(env_for("/api/sessions/s1/stream?from_seq=abc"))

      expect(body.instance_variable_get(:@cursor)).to be_nil
    end
  end

  describe "GET /api/sessions/:id" do
    it "includes last_event_seq = stripped chunk count when no bridge is live" do
      manager = FakeResponsesManager.new(responses: %w[one two three])
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload["last_event_seq"]).to eq(3)
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
    it "spawns with bridge:true by default" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager)
      status, _headers, body = app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(201)
      expect(manager.spawn_calls.last[:bridge]).to be(true)
      expect(JSON.parse(body.first)).to have_key("id")
    end

    it "spawns without a bridge when SAMAGOTCHI_DISABLE_BRIDGE=1" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("SAMAGOTCHI_DISABLE_BRIDGE", "").and_return("1")
      manager = FakeResponsesManager.new
      app = build_app(manager: manager)
      status, _status, _body = app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(201)
      expect(manager.spawn_calls.last[:bridge]).to be(false)
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