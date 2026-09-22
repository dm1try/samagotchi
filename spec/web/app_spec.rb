# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"
require "rack/mock"
require "rack/request"

require "samagotchi/web/app"
require "samagotchi/session"

# Emulates SessionManager#read_responses over an in-memory response list,
# optionally filtering by mtime threshold using a parallel +times+ array.
class FakeResponsesManager
  attr_accessor :responses, :times
  attr_reader :spawn_calls, :resume_calls

  def initialize(responses: [], times: nil)
    @responses = responses
    @times = times
    @spawn_calls = []
    @resume_calls = []
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

  def resume_session(id, state_dir: nil); @resume_calls << [id, state_dir]; nil; end
  def write_turn_input(_id, prompt:, client_id: nil, enqueued_id: nil, state_dir: nil); true; end
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
  def build_app(manager: nil, state_dir: nil, markdown: false, session_class: StubSessionLoader)
    manager ||= FakeResponsesManager.new
    described_class.new(
      manager: manager,
      state_dir: state_dir,
      session_class: session_class,
      bridge_wait_timeout: 0,
      markdown: markdown
    )
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
    it "keeps Markdown disabled by default" do
      app = build_app(state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      message = JSON.parse(body.first).fetch("messages").last
      expect(message).to include("role" => "assistant", "content" => "hi there")
      expect(message).not_to have_key("html")
      expect(JSON.parse(body.first)["markdown_warning"]).to be_nil
    end

    it "reports a warning when Markdown is enabled without commonmarker" do
      renderer = Samagotchi::Web::MarkdownRenderer.new(enabled: true)
      renderer.instance_variable_set(:@commonmarker_available, false)

      expect(renderer.available?).to be(false)
      expect(renderer.warning).to include("gem install commonmarker")
    end

    it "includes sanitized Markdown HTML for assistant messages when available" do
      loader = Class.new do
        class << self
          def load(_id, state_dir: nil)
            s = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
            s.messages = [
              { role: "user", content: "hello" },
              { role: "assistant", content: "see [example](https://example.test) here" }
            ]
            s
          end

          def session_dir(id, state_dir: nil)
            File.join(state_dir.to_s, id)
          end
        end
      end
      app = build_app(state_dir: Dir.mktmpdir, markdown: true, session_class: loader)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      message = JSON.parse(body.first).fetch("messages").last
      expect(message).to include("role" => "assistant")
      expect(message["html"]).to include('href="https://example.test"')
      expect(message["html"]).to include('target="_blank"')
      expect(message["html"]).to include('rel="noopener noreferrer"')
    end

    it "includes last_event_seq = nil when no bridge is live" do
      manager = FakeResponsesManager.new(responses: %w[one two three])
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload["last_event_seq"]).to be_nil
      expect(payload["messages"].map { |m| m["content"] }).to eq(%w[hello hi\ there])
    end

    it "renders a live session from the worker's snapshot: its messages, the turn in progress and its seq" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      live = {
        "snapshot" => {
          "messages" => [
            { "role" => "system", "content" => "sys" },
            { "role" => "user", "content" => "first" },
            { "role" => "model", "content" => "<think>hm</think>answer" },
            { "role" => "tool_response", "content" => "raw" },
            { "role" => "user", "content" => "second" }
          ],
          "current_turn" => { "prompt" => "second", "parts" => [{ "kind" => "text", "text" => "so far" }],
                              "pending_question" => { "id" => "q1", "status" => "pending" } },
          "queued" => [{ "enqueued_id" => "e1", "client_id" => "tui:1", "prompt" => "next" }],
          "event_seq" => 40
        },
        "session_state_snapshot" => { "status" => "running", "event_seq" => 40 }
      }
      allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload["messages"]).to eq([
        { "role" => "user", "content" => "first" },
        { "role" => "assistant", "content" => "answer" },
        { "role" => "user", "content" => "second" }
      ])
      expect(payload["current_turn"]["parts"]).to eq([{ "kind" => "text", "text" => "so far" }])
      expect(payload["queued"].map { |q| q["prompt"] }).to eq(["next"])
      expect(payload["pending_question"]).to eq("id" => "q1", "status" => "pending")
      expect(payload["last_event_seq"]).to eq(40)
      expect(payload.dig("session", "status")).to eq("running")
    end

    it "uses the bridge event_seq when a live bridge reports it" do
      app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_event_seq).and_return(12)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      expect(JSON.parse(body.first)["last_event_seq"]).to eq(12)
    end

    it "does not resume a dead session on preview — read-only, wake on POST /turn" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(nil)

      status, _headers, _body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      expect(manager.resume_calls).to be_empty
    end

    it "does not resume when the bridge is already live" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(4567)

      app.call(env_for("/api/sessions/s1"))

      expect(manager.resume_calls).to be_empty
    end

    it "includes persisted timing details without failing when analytics are absent" do
      state_dir = Dir.mktmpdir
      timing_dir = File.join(state_dir, "s1")
      FileUtils.mkdir_p(timing_dir)
      File.write(
        File.join(timing_dir, "analytics.json"),
        JSON.generate(
          started_at: "2026-09-21T10:00:00.000Z",
          last_activity_at: "2026-09-21T10:00:03.000Z",
          turn_records: [{ id: "turn-1", duration_ms: 3000, status: "completed" }],
          tool_records: [{ id: "tool-1", duration_ms: 50, tool: "read" }]
        )
      )
      app = build_app(manager: FakeResponsesManager.new, state_dir: state_dir)

      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      timing = JSON.parse(body.first).fetch("timing")
      expect(timing["session_duration_ms"]).to eq(3000)
      expect(timing["turn_records"]).to include(hash_including("id" => "turn-1"))
      expect(timing["tool_records"]).to include(hash_including("id" => "tool-1"))
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
      expect(body.first).to include("/assets/app.js")
    end
  end

  describe "session_to_json" do
    it "includes first_preview in the session payload" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      session.first_preview = "cached preview"
      session.last_prompt = "original prompt"

      json = app.send(:session_to_json, session)
      expect(json[:first_preview]).to eq("cached preview")
      expect(json[:last_prompt]).to eq("original prompt")
    end

    it "uses first_preview over last_prompt when both present" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      session.first_preview = "first user message"
      session.last_prompt = "last prompt"

      json = app.send(:session_to_json, session)
      expect(json[:first_preview]).to eq("first user message")
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

  describe "session status" do
    let(:state_dir) { Dir.mktmpdir("web-status-spec") }
    let(:app) { build_app(manager: Samagotchi::SessionManager, state_dir: state_dir, session_class: Samagotchi::Session) }

    after { FileUtils.rm_rf(state_dir) }

    def saved_session(status)
      Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
        s.status = status
        s.save(state_dir: state_dir)
      end
    end

    it "shows a 'running' left behind by a dead worker as idle, in the list and the session view" do
      session = saved_session("running")
      allow(app).to receive(:bridge_get_json).and_return(nil)
      allow(app).to receive(:bridge_event_seq).and_return(nil)

      _, _, list = app.call(env_for("/api/sessions"))
      _, _, show = app.call(env_for("/api/sessions/#{session.id}"))

      expect(JSON.parse(list.first).map { |s| s["status"] }).to eq(["idle"])
      expect(JSON.parse(show.first).dig("session", "status")).to eq("idle")
    end

    it "takes the turn state from the live worker when there is one" do
      session = saved_session("running")
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), kind: "worker")
      allow(app).to receive(:bridge_get_json).and_return("session_state_snapshot" => { "status" => "idle", "event_seq" => 3 })

      _, _, show = app.call(env_for("/api/sessions/#{session.id}"))
      _, _, list = app.call(env_for("/api/sessions"))

      expect(JSON.parse(show.first).dig("session", "status")).to eq("idle")
      # The list trusts disk for a live worker (it saves "running" before each turn).
      expect(JSON.parse(list.first).map { |s| s["status"] }).to eq(["running"])
    ensure
      lock&.release
    end
  end

  describe "POST /api/sessions/:id/turn" do
    it "enqueues through the live bridge, forwarding the client id and returning the bridge's enqueued_id" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(app).to receive(:live_bridge_client).with("s1").and_return(bridge)
      allow(bridge).to receive(:post_turn).with(prompt: "hi", client_id: "web:tab-1").and_return(
        Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e-bridge","session_id":"s1"}')
      )
      expect(manager).not_to receive(:write_turn_input)

      status, _headers, body = app.call(env_for("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"hi","client_id":"web:tab-1"}'))

      expect(status).to eq(202)
      expect(JSON.parse(body.first)).to include("status" => "accepted", "enqueued_id" => "e-bridge", "session_id" => "s1")
      expect(manager.resume_calls.map(&:first)).to eq(["s1"])
    end

    it "falls back to the input file when no bridge comes up" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      allow(app).to receive(:live_bridge_client).and_return(nil)
      queued = nil
      expect(manager).to receive(:write_turn_input) { |id, **kw| queued = [id, kw]; true }

      status, _headers, body = app.call(env_for("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"hi","client_id":"web:tab-1"}'))

      expect(status).to eq(202)
      ack = JSON.parse(body.first)
      expect(ack).to include("status" => "accepted", "enqueued_id" => kind_of(String))
      expect(queued).to match(["s1", { prompt: "hi", client_id: "web:tab-1", enqueued_id: ack["enqueued_id"], state_dir: anything }])
    end
  end

  describe "a session owned by the interactive TUI" do
    let(:state_dir) { Dir.mktmpdir("web-owner-spec") }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
        s.save(state_dir: state_dir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
    let(:app) { build_app(manager: Samagotchi::SessionManager, state_dir: state_dir, session_class: Samagotchi::Session) }

    after do
      @lock&.release
      FileUtils.rm_rf(state_dir)
    end

    def input_files
      Dir.glob(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR, "*"))
    end

    it "answers POST /turn with 409 and queues nothing" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:spawn)

      status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(409)
      expect(JSON.parse(body.first)).to include("error" => "owned_by_tui")
      expect(Process).not_to have_received(:spawn)
      expect(input_files).to be_empty
    end

    it "withdraws a turn written just as a TUI took the session" do
      allow(Samagotchi::SessionManager).to receive(:resume_session) do
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
        session
      end

      status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(409)
      expect(JSON.parse(body.first)).to include("error" => "owned_by_tui")
      expect(input_files).to be_empty
    end

    it "answers POST /stop with 409 and signals nothing" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:kill)

      status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/stop", method: "POST"))

      expect(status).to eq(409)
      expect(JSON.parse(body.first)).to include("error" => "owned_by_tui")
      expect(Process).not_to have_received(:kill)
      expect(Samagotchi::Session.load(session.id, state_dir: state_dir).status).not_to eq("stopped")
    end
  end

  describe "POST /api/sessions/:id/answer" do
    it "returns 400 when the question id is missing" do
      app = build_app(state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/answer", method: "POST", body: '{"selected":["A"]}')
      )

      expect(status).to eq(400)
      expect(JSON.parse(body.first)).to include("error" => "missing_fields")
    end

    it "returns 503 not_live when there is no live bridge for the session" do
      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(nil)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/answer", method: "POST", body: '{"id":"q-1","selected":["A"]}')
      )

      expect(status).to eq(503)
      expect(JSON.parse(body.first)).to include("error" => "not_live")
    end

    it "proxies the answer to the live bridge and returns 200 on success" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      received = nil
      accept_thread = Thread.new do
        conn = server.accept
        request = +""
        request << conn.readpartial(16_384) until request.include?("\r\n\r\n")
        if (m = /Content-Length: (\d+)/i.match(request))
          body_len = m[1].to_i
          body_start = request.index("\r\n\r\n") + 4
          request << conn.readpartial(16_384) while request.bytesize - body_start < body_len
        end
        received = request
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        conn.close
      end
      accept_thread.report_on_exception = false

      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(port)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/answer", method: "POST", body: '{"id":"q-9","selected":["Cats"],"freeform":"meow"}')
      )
      server.close
      accept_thread.join(1)

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to include("status" => "answered", "id" => "q-9")
      expect(received).to include("POST /session/s1/answer HTTP/1.1")
      expect(received).to include(%q{"id":"q-9"})
      expect(received).to include(%q{"selected":["Cats"]})
      expect(received).to include(%q{"freeform":"meow"})
    end

    it "accepts the answer nested under an answer key" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      accept_thread = Thread.new do
        conn = server.accept
        conn.readpartial(16_384)
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}")
        conn.close
      end
      accept_thread.report_on_exception = false

      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(port)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/answer", method: "POST", body: '{"answer":{"id":"q-7","selected":["Dogs"]}}')
      )
      server.close
      accept_thread.join(1)

      expect(status).to eq(200)
      expect(JSON.parse(body.first)).to include("status" => "answered", "id" => "q-7")
    end

    it "passes the bridge's 409 through when another client answered first" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.ip_port
      accept_thread = Thread.new do
        conn = server.accept
        conn.readpartial(16_384)
        reply = '{"error":"question_not_pending","detail":"question already answered"}'
        conn.write("HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
        conn.close
      end
      accept_thread.report_on_exception = false

      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:bridge_sidecar_port).and_return(port)
      status, _headers, body = app.call(
        env_for("/api/sessions/s1/answer", method: "POST", body: '{"id":"q-7","selected":["Dogs"]}')
      )
      server.close
      accept_thread.join(1)

      expect(status).to eq(409)
      expect(JSON.parse(body.first)).to include("error" => "question_not_pending", "detail" => "question already answered")
    end
  end
end