# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "stringio"
require "rack/mock"
require "rack/request"

require "samagotchi/web/app"
require "samagotchi/web/session_hub"
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

  def list_sessions(state_dir: nil, sort: nil, order: nil, limit: nil, offset: 0, **)
    []
  end

  def retention_sweep_if_due(state_dir: nil)
    nil
  end

  def resume_session(id, state_dir: nil); @resume_calls << [id, state_dir]; nil; end
  def write_turn_input(_id, prompt:, client_id: nil, enqueued_id: nil, state_dir: nil); true; end
  def stop_session(_id, state_dir: nil, wait: nil); nil; end
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
  # view: nil leaves the app's own default (the turn view).
  def build_app(manager: nil, state_dir: nil, markdown: false, view: nil, session_class: StubSessionLoader, **extra)
    manager ||= FakeResponsesManager.new
    described_class.new(
      manager: manager,
      state_dir: state_dir,
      session_class: session_class,
      bridge_wait_timeout: 0,
      markdown: markdown,
      **(view.nil? ? {} : { view: view }),
      **extra
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


  describe "log lines (tag web)" do
    let(:log_dir) { Dir.mktmpdir("samagotchi-log") }
    let(:log_path) { File.join(log_dir, "chi.log") }
    after { FileUtils.remove_entry(log_dir) }

    def web_records
      return [] unless File.exist?(log_path)

      File.open(log_path) { |io| Samagotchi::LogLine.each_record(io).select { |r| r.tag == "web" } }
    end

    it "writes API requests at debug level, with the session's sid, and not the page or assets" do
      Samagotchi::Log.configure(path: log_path, level: :debug)
      app = build_app(state_dir: Dir.mktmpdir)
      app.call(env_for("/api/sessions/0123456789abcdef/stream?token=x"))
      app.call(env_for("/"))

      expect(web_records.map { |r| [r.level, r.event, r.sid, r.fields.except("ms")] }).to eq([
        ["DEBUG", "request", "01234567", { "method" => "GET", "path" => "/api/sessions/0123456789abcdef/stream", "status" => "503" }]
      ])
    end

    it "marks the end-of-turn tail read, so the log tells it from a full one (still no query)" do
      Samagotchi::Log.configure(path: log_path, level: :debug)
      app = build_app(state_dir: Dir.mktmpdir)
      app.call(env_for("/api/sessions/0123456789abcdef?tail=1"))
      app.call(env_for("/api/sessions/0123456789abcdef"))

      expect(web_records.map { |r| r.fields.except("ms") }).to eq([
        { "method" => "GET", "path" => "/api/sessions/0123456789abcdef", "status" => "200", "tail" => "true" },
        { "method" => "GET", "path" => "/api/sessions/0123456789abcdef", "status" => "200" }
      ])
    end

    it "writes nothing per request at the default level" do
      Samagotchi::Log.configure(path: log_path)
      build_app(state_dir: Dir.mktmpdir).call(env_for("/api/sessions"))

      expect(web_records).to be_empty
    end

    it "writes an internal error as an ERROR with the backtrace" do
      Samagotchi::Log.configure(path: log_path)
      app = build_app(state_dir: Dir.mktmpdir)
      allow(app).to receive(:handle_list).and_raise(RuntimeError, "boom")

      status, = app.call(env_for("/api/sessions"))

      expect(status).to eq(500)
      record = web_records.first
      expect(record.to_h).to include(level: "ERROR", event: "request_failed")
      expect(record.fields).to include("method" => "GET", "path" => "/api/sessions", "error" => "RuntimeError", "msg" => "boom")
      expect(record.payload).not_to be_empty
    end
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

  describe "GET /api/events" do
    let(:state_dir) { Dir.mktmpdir("web-events-spec") }
    let(:hub) { Samagotchi::Web::SessionHub.new(state_dir: state_dir) }

    after { FileUtils.rm_rf(state_dir) }

    def events_app(hub: self.hub, **kw)
      described_class.new(manager: Samagotchi::SessionManager, session_class: Samagotchi::Session, state_dir: state_dir,
                          bridge_wait_timeout: 0, hub: hub, events_heartbeat: 0.01, **kw)
    end

    def saved_session(project_root: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
        s.project_root = project_root
        s.save(state_dir: state_dir)
      end
    end

    # The frames a body yields until it ends (the hub is stopped, or the
    # queue overflowed): [[event, data], ...], pings left out.
    def frames_of(body)
      raw = +""
      body.each { |chunk| raw << chunk }
      raw.split("\r\n\r\n").reject { |f| f.start_with?(":") }.map do |frame|
        lines = frame.split("\r\n")
        [lines.find { |l| l.start_with?("event: ") }&.delete_prefix("event: "),
         JSON.parse(lines.select { |l| l.start_with?("data: ") }.map { |l| l.delete_prefix("data: ") }.join)]
      end
    end

    it "answers 503 no_hub without a hub, so the page falls back to fetching" do
      status, _, body = build_app(state_dir: state_dir).call(env_for("/api/events"))

      expect(status).to eq(503)
      expect(JSON.parse(body.first)).to include("error" => "no_hub")
    end

    it "opens with the hub's snapshot, then a session frame for each change the hub sees, until the hub stops" do
      a = saved_session
      hub.scan
      app = events_app
      status, headers, body = app.call(env_for("/api/events"))
      expect(status).to eq(200)
      expect(headers["Content-Type"]).to eq("text/event-stream")

      collected = Thread.new { frames_of(body) }
      b = saved_session
      hub.touch(b.id)
      File.delete(File.join(state_dir, "#{a.id}.json"))
      hub.touch(a.id)
      hub.stop

      frames = collected.value
      expect(frames.map(&:first)).to eq(%w[snapshot session session_gone])
      expect(frames[0][1]["sessions"].map { |s| s["id"] }).to eq([a.id])
      expect(frames[0][1]["sessions"].first).to include("bridge_up" => false, "owner" => nil)
      expect(frames[1][1]["session"]).to include("id" => b.id)
      expect(frames[2][1]).to eq("id" => a.id)
    end

    it "carries the hub's seq as the frame id, and pings while idle" do
      hub.scan
      app = events_app
      _, _, body = app.call(env_for("/api/events"))
      raw = +""
      collected = Thread.new { body.each { |chunk| raw << chunk } }
      hub.touch(saved_session.id)
      sleep 0.05
      hub.stop
      collected.join(2)

      expect(raw).to include("id: 1\r\nevent: session\r\n")
      expect(raw).to include(": ping\r\n\r\n")
    end

    it "scopes the snapshot and the session frames to ?dir's project, and answers 400 for a folder that isn't one" do
      here = Samagotchi::ProjectScope.root_for(__dir__) # the main repo, for a worktree too
      mine = saved_session(project_root: here)
      saved_session(project_root: "/repo/other")
      hub.scan
      app = events_app
      status, _, body = app.call(env_for("/api/events?dir=#{URI.encode_www_form_component(__dir__)}"))
      expect(status).to eq(200)
      collected = Thread.new { frames_of(body) }
      other = saved_session(project_root: "/repo/other")
      hub.touch(other.id)
      again = saved_session(project_root: here)
      hub.touch(again.id)
      hub.stop

      frames = collected.value
      expect(frames.map(&:first)).to eq(%w[snapshot session])
      expect(frames[0][1]["sessions"].map { |s| s["id"] }).to eq([mine.id])
      expect(frames[1][1]["session"]["id"]).to eq(again.id)

      status, = app.call(env_for("/api/events?dir=/no/such/folder"))
      expect(status).to eq(400)
    end

    it "ends the connection when its queue overflowed: the reconnect's snapshot is the recovery" do
      hub.scan
      app = events_app(events_queue: 2)
      _, _, body = app.call(env_for("/api/events"))
      3.times { hub.touch(saved_session.id) }

      frames = frames_of(body) # ends on its own, no hub.stop
      expect(frames.first.first).to eq("snapshot")
      expect(frames.size).to be < 4
    end

    it "ends the connection once the server is shutting down" do
      hub.scan
      app = events_app
      running = true
      app.server_running = -> { running }
      _, _, body = app.call(env_for("/api/events"))
      collected = Thread.new { frames_of(body) }
      running = false

      expect(collected.join(2)).not_to be_nil
    end

    it "streams straight to the socket under rack.hijack, as the session stream does" do
      hub.scan
      app = events_app
      status, headers, body = app.call(env_for("/api/events", headers: { "rack.hijack?" => true }))
      expect(status).to eq(200)
      expect(body).to eq([])
      out = StringIO.new
      writer = Thread.new { headers["rack.hijack"].call(out) }
      hub.touch(saved_session.id)
      hub.stop
      writer.join(2)

      expect(out.string).to start_with("event: snapshot\r\n")
      expect(out.string).to include("event: session\r\n")
    end

    it "logs the connect as one request line at debug level" do
      log_dir = Dir.mktmpdir
      Samagotchi::Log.configure(path: File.join(log_dir, "chi.log"), level: :debug)
      hub.scan
      hub.stop
      events_app.call(env_for("/api/events")).last.each { |_c| nil }

      records = File.open(File.join(log_dir, "chi.log")) { |io| Samagotchi::LogLine.each_record(io).select { |r| r.tag == "web" } }
      expect(records.map { |r| [r.event, r.fields["path"], r.fields["status"]] }).to eq([["request", "/api/events", "200"]])
    ensure
      FileUtils.remove_entry(log_dir)
    end
  end

  describe "with a session hub" do
    let(:state_dir) { Dir.mktmpdir("web-hub-spec") }
    let(:hub) { Samagotchi::Web::SessionHub.new(state_dir: state_dir) }
    let(:app) do
      described_class.new(manager: Samagotchi::SessionManager, session_class: Samagotchi::Session, state_dir: state_dir,
                          bridge_wait_timeout: 0, hub: hub)
    end

    after { FileUtils.rm_rf(state_dir) }

    def saved_session(status: "idle")
      Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd).tap do |s|
        s.status = status
        s.save(state_dir: state_dir)
      end
    end

    it "lists from the projection: Session.list's order, pagination and total, with owner, status and recap" do
      sessions = 3.times.map { saved_session(status: "running") }
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(sessions[0].id, state_dir: state_dir), kind: "worker")
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(sessions[1].id, state_dir: state_dir))
      File.write(File.join(Samagotchi::Session.session_dir(sessions[1].id, state_dir: state_dir), "recap.json"),
                 JSON.generate(text: "We fixed the login. Then the tests.", covered: 2))
      hub.scan

      _, _, body = app.call(env_for("/api/sessions"))
      listed = JSON.parse(body.first)
      expect(listed.map { |s| s["id"] }).to eq(Samagotchi::Session.list(state_dir: state_dir).map(&:id))
      expect(listed.to_h { |s| [s["id"], [s["owner"], s["status"], s["recap"]]] }).to eq(
        sessions[0].id => ["worker", "running", nil],
        sessions[1].id => [nil, "idle", "We fixed the login."],
        sessions[2].id => [nil, "idle", nil]
      )

      _, headers, body = app.call(env_for("/api/sessions?sort=created_at&order=asc&limit=2&offset=1"))
      expect(JSON.parse(body.first).map { |s| s["id"] })
        .to eq(Samagotchi::Session.list(state_dir: state_dir, sort: "created_at", order: "asc", limit: 2, offset: 1).map(&:id))
      expect(headers["X-Total-Count"]).to eq("3")

      # The projection is the source: a file the tick hasn't seen isn't listed yet.
      saved_session
      _, _, body = app.call(env_for("/api/sessions"))
      expect(JSON.parse(body.first).size).to eq(3)
    ensure
      lock&.release
    end

    it "scopes the list by ?dir's project from the projection, and gives the sweep its chance" do
      here = Samagotchi::ProjectScope.root_for(__dir__)
      mine = saved_session
      other = saved_session
      mine.project_root = here
      mine.save(state_dir: state_dir)
      other.project_root = "/repo/other"
      other.save(state_dir: state_dir)
      hub.scan
      allow(Samagotchi::SessionManager).to receive(:retention_sweep_if_due)

      _, _, body = app.call(env_for("/api/sessions?dir=#{URI.encode_www_form_component(__dir__)}"))

      expect(JSON.parse(body.first).map { |s| s["id"] }).to eq([mine.id])
      expect(Samagotchi::SessionManager).to have_received(:retention_sweep_if_due).with(state_dir: state_dir)
    end

    it "answers 400 invalid_model for a model whose host isn't configured" do
      manager = Class.new(FakeResponsesManager) do
        def spawn_session(prompt:, state_dir: nil, **kw)
          raise Samagotchi::ModelProfile::UnknownHost, "unknown host 'nosuch' in model '#{kw[:model_name]}'"
        end
      end.new
      app = described_class.new(manager: manager, session_class: Samagotchi::Session, state_dir: state_dir,
                                bridge_wait_timeout: 0, hub: hub)

      status, _, body = app.call(env_for("/api/sessions", method: "POST",
                                                          body: JSON.generate(prompt: "hi", model: "nosuch:org/model")))

      expect(status).to eq(400)
      expect(JSON.parse(body.first)).to include("error" => "invalid_model",
                                                "detail" => "unknown host 'nosuch' in model 'nosuch:org/model'")
    end

    it "has the projection hold a created session before the 201 goes out" do
      manager = Class.new(FakeResponsesManager) do
        def spawn_session(prompt:, state_dir: nil, **kw)
          super.tap { |s| s.save(state_dir: state_dir) }
        end
      end.new
      app = described_class.new(manager: manager, session_class: Samagotchi::Session, state_dir: state_dir,
                                bridge_wait_timeout: 0, hub: hub)
      seen = []
      hub.subscribe(->(event) { seen << event.type })

      status, _, body = app.call(env_for("/api/sessions", method: "POST", body: JSON.generate(prompt: "hi")))

      expect(status).to eq(201)
      id = JSON.parse(body.first)["id"]
      expect(hub.snapshot.map { |s| s[:id] }).to eq([id])
      expect(seen).to eq(%w[session])
    end

    it "has the projection drop a deleted session before the 200 goes out" do
      session = saved_session
      hub.scan
      seen = []
      hub.subscribe(->(event) { seen << event.type })

      status, = app.call(env_for("/api/sessions/#{session.id}", method: "DELETE"))

      expect(status).to eq(200)
      expect(hub.snapshot).to eq([])
      expect(seen).to eq(%w[session_gone])
    end

    it "rescans a stopped session before answering the stop" do
      session = saved_session(status: "running")
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), kind: "worker")
      hub.scan
      allow(Samagotchi::SessionManager).to receive(:stop_session) { lock.release }
      seen = []
      hub.subscribe(->(event) { seen << [event.data[:session][:owner], event.data[:session][:status]] })

      status, = app.call(env_for("/api/sessions/#{session.id}/stop", method: "POST"))

      expect(status).to eq(200)
      # The worker is gone, so the file's "running" now shows idle.
      expect(seen).to eq([[nil, "idle"]])
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

    it "keeps the history's layout: code indentation and nested lists" do
      app = build_app(state_dir: Dir.mktmpdir)
      answer = "- a\n  - nested\n\n```python\ndef f(x):\n    return  1\n```"
      live = { "snapshot" => { "messages" => [
        { "role" => "user", "content" => "fix:\n    x  = 1" },
        { "role" => "model", "content" => "<think>hm</think>#{answer}" }
      ] } }
      allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
      _status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(JSON.parse(body.first)["messages"].map { |m| m["content"] }).to eq(["fix:\n    x  = 1", answer])
    end

    it "shows a context note as a note, with who sent it, from a live snapshot or the file" do
      app = build_app(state_dir: Dir.mktmpdir)
      note = Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack")
      peer = Samagotchi::ContextNote.message(note_id: "n2", text: "api moved", source: "session",
                                             from_session: "3f2a1c00-aaaa", from_cwd: "/work/foo")
      live = { "snapshot" => { "messages" => [
        { "role" => "system", "content" => "sys" },
        { "role" => "user", "content" => "hi" },
        note.transform_keys(&:to_s),
        { "role" => "system", "content" => "[SYSTEM: REMINDERS DUE]\n  x\n[END REMINDERS]" },
        peer.transform_keys(&:to_s)
      ] } }
      allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)

      _status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(JSON.parse(body.first)["messages"]).to eq([
        { "role" => "user", "content" => "hi" },
        { "role" => "note", "content" => "deploy frozen", "label" => "slack" },
        { "role" => "note", "content" => "api moved", "label" => "session 3f2a1c (/work/foo)" }
      ])
      expect(app.send(:messages_for_display, [note])).to eq([{ role: "note", content: "deploy frozen", label: "slack" }])
    end

    it "shows a plugin's steer as role steer with its source and the step that answered it, never as a prompt" do
      messages = [{ role: "user", content: "look" },
                  { role: "model", content: "", tool_calls: [{ id: "c1", name: "read" }] },
                  { role: "tool_response", content: "[read]\nx" },
                  { role: "model", content: "reading more" },
                  { role: "tool_response", content: "[read]\ny" },
                  Samagotchi::Steer.message(text: "status?", source: "check-in"),
                  { role: "model", content: "found it" }]

      shown = build_app(state_dir: Dir.mktmpdir).send(:messages_for_display, messages)

      expect(shown).to eq([{ role: "user", content: "look" }, { role: "assistant", content: "reading more" },
                           { role: "steer", content: "status?", source: "check-in", step: 3 },
                           { role: "assistant", content: "found it" }])
    end

    it "includes last_event_seq = nil when no bridge is live" do
      manager = FakeResponsesManager.new(responses: %w[one two three])
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      status, _headers, body = app.call(env_for("/api/sessions/s1"))

      expect(status).to eq(200)
      payload = JSON.parse(body.first)
      expect(payload["last_event_seq"]).to be_nil
      expect(payload["last_event_id"]).to be_nil
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
          "recap" => "We did things.",
          "saved_recap" => { "text" => "We did things.", "covered" => 4, "turns_since" => 0, "created_at" => "t" },
          "continue_offer" => { "context" => { "original_prompt" => "first" }, "no_interrupt" => false },
          "guardrail_warning" => "hook g.rb (config) failed to load (x)",
          "plugin_warning" => "plugin plugin.rb (bundle b) failed to load (x)",
          "init_tasks" => [{ "bundle" => "mcp", "id" => "mcp-1", "label" => "Starting MCP server x" }],
          "commands" => [{ "name" => "/hello", "description" => "greet", "anytime" => true, "local" => false,
                           "uis" => nil, "source" => "sample-plugin" }],
          "event_seq" => 40,
          "event_id" => "40-e1"
        },
        "session_state_snapshot" => { "status" => "running", "event_seq" => 40, "model_name" => "Qwen3-14B",
                                      "served_model" => "ornith-1.5", "served_model_for" => "Qwen3-14B" }
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
      # The cursor to stream on from: it names the worker (its epoch).
      expect(payload["last_event_id"]).to eq("40-e1")
      expect(payload["recap"]).to eq("We did things.")
      expect(payload["saved_recap"]).to eq("text" => "We did things.", "turns_since" => 0)
      expect(payload["continue_offer"]).to eq("context" => { "original_prompt" => "first" }, "no_interrupt" => false)
      expect(payload["guardrail_warning"]).to eq("hook g.rb (config) failed to load (x)")
      expect(payload["plugin_warning"]).to eq("plugin plugin.rb (bundle b) failed to load (x)")
      expect(payload["init_tasks"]).to eq([{ "bundle" => "mcp", "id" => "mcp-1", "label" => "Starting MCP server x" }])
      # The composer's autocomplete: the worker's commands, its plugins' too.
      expect(payload["commands"].map { |c| c["name"] }).to eq(["/hello"])
      expect(payload.dig("session", "status")).to eq("running")
      # The model turns run on now (after a /model), not the file's.
      expect(payload.dig("session", "model_name")).to eq("Qwen3-14B")
      # What the worker's server said it served for it.
      expect(payload.dig("session", "served_model")).to eq("ornith-1.5")
      expect(payload.dig("session", "served_model_for")).to eq("Qwen3-14B")
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

    it "shows a stopped session's saved recap, with the turns since it (no worker woken)" do
      state_dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(state_dir, "s1"))
      # StubSessionLoader's session: user "hello", assistant "hi there".
      File.write(File.join(state_dir, "s1", "recap.json"), JSON.generate(text: "We said hello.", covered: 1, covered_digest: "x"))
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: state_dir)

      payload = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)

      expect(payload["recap"]).to be_nil
      expect(payload["saved_recap"]).to eq("text" => "We said hello.", "turns_since" => 0)
      expect(manager.resume_calls).to be_empty

      File.write(File.join(state_dir, "s1", "recap.json"), JSON.generate(text: "Earlier.", covered: 0, covered_digest: "x"))
      payload = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)
      expect(payload["saved_recap"]).to eq("text" => "Earlier.", "turns_since" => 1)
    end

    describe "an answer's display (AnswerDisplay, set by an after_turn hook)" do
      let(:answer) { "see JIRA-1 and `JIRA-1`" }
      let(:display) { "see [JIRA-1](https://j.test/browse/JIRA-1) and `JIRA-1`" }
      let(:live) do
        { "snapshot" => { "messages" => [
          { "role" => "user", "content" => "q" },
          { "role" => "model", "content" => answer, "display" => display }
        ] }, "session_state_snapshot" => { "status" => "idle", "event_seq" => 3 } }
      end

      def answer_of(app, query)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
        JSON.parse(app.call(env_for("/api/sessions/s1#{query}"))[2].first)["messages"].last
      end

      it "renders the display in place of the answer, on the tail, the full and the parts read; content stays the model's" do
        app = build_app(state_dir: Dir.mktmpdir, markdown: true)

        ["?tail=1", "", "?parts=1"].each do |query|
          message = answer_of(app, query)
          expect(message).to include("content" => answer, "display" => display)
          expect(message["html"]).to include('<a href="https://j.test/browse/JIRA-1"')
          expect(message["html"]).to include("<code>JIRA-1</code>")
        end
      end

      it "reads it from a stopped session's file (symbol keys)" do
        loader = Class.new(StubSessionLoader) do
          def self.load(id, state_dir: nil)
            super.tap { |s| s.messages = [{ role: "user", content: "q" }, { role: "model", content: "a JIRA-1", display: "a [JIRA-1](https://j.test/JIRA-1)" }] }
          end
        end
        app = build_app(state_dir: Dir.mktmpdir, markdown: true, session_class: loader)

        message = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)["messages"].last

        expect(message["html"]).to include('href="https://j.test/JIRA-1"')
      end

      it "sanitises it like an answer: no raw HTML, no script links" do
        live["snapshot"]["messages"].last["display"] =
          %(<script>alert(1)</script>\n\ntext <img src=x onerror="alert(2)"> <b onclick="x()">b</b>\n\n[a](javascript:alert(3)) [ok](https://ok.test))
        message = answer_of(build_app(state_dir: Dir.mktmpdir, markdown: true), "?tail=1")
        html = Nokogiri::HTML5.fragment(message["html"])

        expect(html.css("script, img, b")).to be_empty
        expect(html.xpath(".//@*").map(&:name)).not_to include(a_string_starting_with("on"))
        expect(html.css("a").map { |a| a["href"] }).to eq([nil, "https://ok.test"])
        expect(html.text).to include("<script>alert(1)</script>")
      end

      it "a blank or non-string display is ignored" do
        live["snapshot"]["messages"].last["display"] = "  "
        message = answer_of(build_app(state_dir: Dir.mktmpdir, markdown: true), "?tail=1")

        expect(message).not_to have_key("display")
        expect(message["html"]).not_to include("<a ")
      end
    end

    describe "?tail=1 (the page's re-read at the end of a turn)" do
      let(:live) do
        { "snapshot" => { "messages" => [
          { "role" => "system", "content" => "sys" },
          { "role" => "user", "content" => "first" },
          { "role" => "model", "content" => "old *answer*" },
          { "role" => "user", "content" => "second" },
          { "role" => "model", "content" => "let me look" },
          { "role" => "tool_response", "content" => "raw" },
          { "role" => "model", "content" => "<think>hm</think>see [x](https://example.test)" }
        ], "recap" => "We did things.", "queued" => [{ "prompt" => "next" }], "event_id" => "40-e1" },
          "session_state_snapshot" => { "status" => "idle", "event_seq" => 40, "model_name" => "Qwen3-14B" } }
      end

      it "answers the session, the timing and the last assistant message only, rendered" do
        manager = FakeResponsesManager.new(responses: %w[one two])
        app = build_app(manager: manager, state_dir: Dir.mktmpdir, markdown: true)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
        allow(manager).to receive(:read_responses).and_call_original

        status, _headers, body = app.call(env_for("/api/sessions/s1?tail=1"))

        expect(status).to eq(200)
        payload = JSON.parse(body.first)
        expect(payload.keys).to contain_exactly("tail", "session", "messages", "markdown_warning", "timing")
        expect(payload["tail"]).to be(true)
        expect(payload["messages"].size).to eq(1)
        expect(payload["messages"].first).to include("role" => "assistant", "content" => "see [x](https://example.test)")
        expect(payload["messages"].first["html"]).to include('href="https://example.test"')
        expect(payload.dig("session", "status")).to eq("idle")
        expect(payload.dig("session", "model_name")).to eq("Qwen3-14B")
        expect(payload["timing"]).to include("turn_records", "tool_records")
        # The responses file is the full answer's alone.
        expect(manager).not_to have_received(:read_responses)
      end

      it "renders only that one message, not the whole history" do
        app = build_app(state_dir: Dir.mktmpdir, markdown: true)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
        renderer = app.instance_variable_get(:@markdown_renderer)
        allow(renderer).to receive(:render).and_call_original

        app.call(env_for("/api/sessions/s1?tail=1"))

        expect(renderer).to have_received(:render).once
      end

      it "a turn with no answer (canceled): the answer before it, as the full list's last one" do
        live["snapshot"]["messages"] << { "role" => "user", "content" => "third" }
        app = build_app(state_dir: Dir.mktmpdir)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)

        payload = JSON.parse(app.call(env_for("/api/sessions/s1?tail=1"))[2].first)

        expect(payload["messages"].map { |m| m["content"] }).to eq(["see [x](https://example.test)"])
      end

      it "no answer yet: no messages; a stopped session reads its file" do
        loader = Class.new(StubSessionLoader) do
          def self.load(id, state_dir: nil)
            super.tap { |s| s.messages = [{ role: "user", content: "hello" }] }
          end
        end
        app = build_app(state_dir: Dir.mktmpdir, session_class: loader)
        expect(JSON.parse(app.call(env_for("/api/sessions/s1?tail=1"))[2].first)["messages"]).to eq([])

        payload = JSON.parse(build_app(state_dir: Dir.mktmpdir).call(env_for("/api/sessions/s1?tail=1"))[2].first)
        expect(payload["messages"]).to eq([{ "role" => "assistant", "content" => "hi there" }])
      end

      it "without tail the answer stays full" do
        app = build_app(state_dir: Dir.mktmpdir)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)

        payload = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)

        expect(payload).not_to have_key("tail")
        expect(payload["messages"].size).to eq(5)
        expect(payload).to include("history", "recap", "queued", "last_event_id")
      end
    end

    describe "cards (the worker's snapshot[:cards])" do
      let(:live) do
        { "snapshot" => { "messages" => [], "cards" => [
          { "type" => "card", "id" => "c1", "source" => "b", "title" => "Hi", "body" => "some **bold** <b>x</b>",
            "level" => "info", "actions" => [{ "label" => "Again", "command" => "/hello again" }],
            "in_turn" => false, "turns_since" => 0, "current" => false },
          { "type" => "card", "id" => "c2", "source" => "b", "title" => "Empty", "body" => "", "level" => "warn",
            "actions" => [], "in_turn" => true, "turns_since" => 1, "current" => false },
          { "type" => "hook_notice", "hook" => "plugin.rb (bundle b)", "text" => "saved", "level" => "info",
            "in_turn" => false, "turns_since" => 0, "current" => false }
        ] }, "session_state_snapshot" => { "status" => "idle", "event_seq" => 9 } }
      end

      def cards_of(app, path)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
        JSON.parse(app.call(env_for(path))[2].first)
      end

      it "hands out each card's body rendered as markdown when the renderer is on; notices as they are" do
        cards = cards_of(build_app(state_dir: Dir.mktmpdir, markdown: true), "/api/sessions/s1")["cards"]

        expect(cards.map { |c| c["id"] || c["type"] }).to eq(%w[c1 c2 hook_notice])
        expect(cards[0]["body_html"]).to include("<strong>bold</strong>")
        expect(cards[0]["body_html"]).not_to include("<b>x</b>")
        expect(cards[0]["actions"]).to eq([{ "label" => "Again", "command" => "/hello again" }])
        expect(cards[1]["body_html"]).to eq("")
        expect(cards[2]).not_to have_key("body_html")
      end

      it "hands out the escaped text in a <pre> without markdown" do
        cards = cards_of(build_app(state_dir: Dir.mktmpdir), "/api/sessions/s1")["cards"]
        expect(cards[0]["body_html"]).to eq("<pre>some **bold** &lt;b&gt;x&lt;/b&gt;</pre>")
      end

      it "answers ?cards=1 with the cards alone (the page's re-read when a card arrives)" do
        payload = cards_of(build_app(state_dir: Dir.mktmpdir), "/api/sessions/s1?cards=1")
        expect(payload.keys).to eq(["cards"])
        expect(payload["cards"].size).to eq(3)
      end

      it "is empty without a live worker" do
        app = build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir)
        expect(JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)["cards"]).to eq([])
      end
    end

    describe "?parts=1 (the turn view's reload: what each step did)" do
      let(:live) do
        { "snapshot" => { "messages" => [
          { "role" => "system", "content" => "sys" },
          { "role" => "user", "content" => "check" },
          { "role" => "model", "content" => "<think>look</think>\nLet me look.\n<tool_call>\n<function=execute>\n" \
                                             "<parameter=command>\nls\n</parameter>\n</function>\n</tool_call>" },
          { "role" => "tool_response", "content" => "[execute]\na.txt" },
          { "role" => "model", "content" => "",
            "tool_calls" => [{ "id" => "c1", "name" => "read", "arguments" => { "path" => "a.txt" } }] },
          { "role" => "tool_response", "content" => "[read]\nhello", "tool_call_id" => "c1" },
          { "role" => "model", "content" => "<think>done</think>It says **hello**." }
        ] }, "session_state_snapshot" => { "status" => "idle", "event_seq" => 9 } }
      end

      def payload_for(app, path)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(live)
        JSON.parse(app.call(env_for(path))[2].first)
      end

      it "hands each assistant message its parts and keeps a text-less step" do
        payload = payload_for(build_app(state_dir: Dir.mktmpdir, markdown: true), "/api/sessions/s1?parts=1")

        steps = payload["messages"].select { |m| m["role"] == "assistant" }
        expect(steps.map { |m| m["content"] }).to eq(["Let me look.", "", "It says **hello**."])
        expect(steps.map { |m| m["parts"] }).to eq([
          { "thinking" => "look", "tools" => [{ "tool" => "execute", "params" => 'command="ls"', "title" => "ls", "output" => "[execute]\na.txt" }] },
          { "tools" => [{ "tool" => "read", "params" => 'path="a.txt"', "title" => "a.txt", "output" => "[read]\nhello" }] },
          { "thinking" => "done" }
        ])
        # Nothing to render for the text-less step.
        expect(steps[1]).not_to have_key("html")
        expect(steps[2]["html"]).to include("<strong>hello</strong>")
      end

      it "titles a file call relative to the session's working directory" do
        app = build_app(state_dir: Dir.mktmpdir)
        messages = [{ "role" => "user", "content" => "check" },
                    { "role" => "model", "content" => "", "tool_calls" => [{ "id" => "c1", "name" => "read",
                                                                               "arguments" => { "path" => "#{Dir.pwd}/lib/x.rb" } }] },
                    { "role" => "tool_response", "content" => "[read]\nx", "tool_call_id" => "c1" }]
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot")
                                               .and_return(live.merge("snapshot" => { "messages" => messages }))
        payload = JSON.parse(app.call(env_for("/api/sessions/s1?parts=1"))[2].first)
        expect(payload["messages"].last["parts"]["tools"].first).to include("title" => "lib/x.rb",
                                                                            "params" => %(path="#{Dir.pwd}/lib/x.rb"))
      end

      it "without it the messages are as before: no parts, no text-less step" do
        payload = payload_for(build_app(state_dir: Dir.mktmpdir), "/api/sessions/s1")

        expect(payload["messages"]).to eq([
          { "role" => "user", "content" => "check" },
          { "role" => "assistant", "content" => "Let me look." },
          { "role" => "assistant", "content" => "It says **hello**." }
        ])
      end

      it "hands out the thinking an api: openai step saved; the chat view's messages don't carry it" do
        openai = { "snapshot" => { "messages" => [
          { "role" => "user", "content" => "check" },
          { "role" => "model", "content" => "", "thinking" => "run it",
            "tool_calls" => [{ "id" => "c1", "name" => "execute", "arguments" => { "command" => "true" } }] },
          { "role" => "tool_response", "content" => "[execute]\n", "tool_call_id" => "c1" },
          { "role" => "model", "content" => "Passed.", "thinking" => "it passed" }
        ] }, "session_state_snapshot" => { "status" => "idle", "event_seq" => 3 } }
        app = build_app(state_dir: Dir.mktmpdir)
        allow(app).to receive(:bridge_get_json).with("s1", "snapshot").and_return(openai)

        turn = JSON.parse(app.call(env_for("/api/sessions/s1?parts=1"))[2].first)["messages"]
        chat = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first)["messages"]

        expect(turn.filter_map { |m| m.dig("parts", "thinking") }).to eq(["run it", "it passed"])
        expect(chat).to eq([{ "role" => "user", "content" => "check" }, { "role" => "assistant", "content" => "Passed." }])
      end

      it "the turn-end tail stays light (no parts)" do
        payload = payload_for(build_app(state_dir: Dir.mktmpdir), "/api/sessions/s1?tail=1&parts=1")

        expect(payload["messages"]).to eq([{ "role" => "assistant", "content" => "It says **hello**." }])
      end
    end

    it "shows a failed turn whose prompt went back to the user (failed_turn), until the next prompt" do
      state_dir = Dir.mktmpdir
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      session.last_prompt = "Say pong"
      session.messages = [Samagotchi::TurnNote.failed("HTTP 500: boom", restored: true)]
      session.save(state_dir: state_dir)
      app = described_class.new(manager: Samagotchi::SessionManager, session_class: Samagotchi::Session,
                                state_dir: state_dir, bridge_wait_timeout: 0)
      read = -> { JSON.parse(app.call(env_for("/api/sessions/#{session.id}"))[2].first) }

      expect(read.call).to include("messages" => [], "failed_turn" => { "prompt" => "Say pong", "summary" => "HTTP 500: boom" })

      session.messages += [{ role: "user", content: "Say pong" }, { role: "model", content: "PONG" }]
      session.save(state_dir: state_dir)
      expect(read.call["failed_turn"]).to be_nil
    ensure
      FileUtils.rm_rf(state_dir)
    end

    it "has no saved recap for a session without one" do
      payload = JSON.parse(build_app(state_dir: Dir.mktmpdir).call(env_for("/api/sessions/s1"))[2].first)
      expect(payload["saved_recap"]).to be_nil
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
      expect(timing).to include("context" => nil, "tokens" => nil)
    end

    # The ctx meter's value on load: a stopped session's saved context.
    it "passes the saved context and token sums through in the timing" do
      state_dir = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(state_dir, "s1"))
      context = { "used_tokens" => 350, "window_tokens" => 4096, "window_source" => "server", "source" => "server",
                  "at" => "2026-09-21T10:00:03.000Z" }
      tokens = { "prompt_sum" => 900, "completion_sum" => 80, "source" => "server" }
      File.write(File.join(state_dir, "s1", "analytics.json"), JSON.generate(context: context, tokens: tokens))
      app = build_app(manager: FakeResponsesManager.new, state_dir: state_dir)

      timing = JSON.parse(app.call(env_for("/api/sessions/s1"))[2].first).fetch("timing")

      expect(timing).to include("context" => context, "tokens" => tokens)
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

  describe "POST /api/sessions with model" do
    it "starts the session on the given model, and on the default without one or with a blank one" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager)
      app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi","model":" box:gemma4-26b "}'))
      app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi","model_name":"Qwen3-14B"}'))
      app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi","model":"  "}'))
      app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi"}'))

      expect(manager.spawn_calls.map { |c| c[:extra] }).to eq([{ model_name: "box:gemma4-26b" }, { model_name: "Qwen3-14B" }, {}, {}])
    end
  end

  describe "POST /api/sessions idle with a preview" do
    it "names the idle session by the first message it is about to get; a prompted session takes none" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager)
      app.call(env_for("/api/sessions", method: "POST", body: '{"idle":true,"preview":" Say pong "}'))
      app.call(env_for("/api/sessions", method: "POST", body: '{"idle":true,"preview":"  "}'))
      app.call(env_for("/api/sessions", method: "POST", body: '{"prompt":"hi","preview":"other"}'))

      expect(manager.spawn_calls.map { |c| [c[:prompt], c[:extra]] }).to eq([[nil, { title: "Say pong" }], [nil, {}], ["hi", {}]])
    end
  end

  # A registry as GET /api/models reads it: list_all_models(force:) answers
  # per host {models:, error:}; default_entry names the default host.
  class FakeModelRegistry
    attr_reader :calls

    def initialize(results, default_host: "default", delay: 0, cached: nil)
      @results = results
      @default_host = default_host
      @delay = delay
      @cached = cached
      @calls = []
    end

    def list_all_models(force: true)
      @calls << force
      sleep @delay if @delay.positive?
      raise @results if @results.is_a?(Exception)

      @results
    end

    def default_entry = Struct.new(:name).new(@default_host)
    def cached_results = @cached
  end

  def model_info(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

  describe "GET /api/models" do
    def models_payload(registry, **opts)
      app = described_class.new(manager: FakeResponsesManager.new, session_class: StubSessionLoader, registry: registry, **opts)
      status, _headers, body = app.call(env_for("/api/models"))
      expect(status).to eq(200)
      JSON.parse(body.first)
    end

    it "lists the default host's models bare and the other hosts' as host:model, the default host first, from the cached lists" do
      registry = FakeModelRegistry.new({
        "box" => { models: [model_info("gemma4-26b"), model_info("qwen3.6")], error: nil },
        "default" => { models: [model_info("Gemma-4B-it"), model_info("Qwen3-14B")], error: nil }
      })

      payload = models_payload(registry)

      expect(payload["default"]).to eq("Gemma-4B-it")
      expect(payload["models"].map { |m| m["name"] }).to eq(%w[Gemma-4B-it Qwen3-14B box:gemma4-26b box:qwen3.6])
      expect(payload["models"].last).to eq("name" => "box:qwen3.6", "host" => "box", "id" => "qwen3.6")
      expect(payload).not_to have_key("warning")
      expect(registry.calls).to eq([false])
    end

    it "keeps the default in the list when no host lists it, and leaves :batch variants out" do
      registry = FakeModelRegistry.new({ "default" => { models: [model_info("other"), model_info("other:batch")], error: nil } })

      payload = models_payload(registry)

      expect(payload["models"].map { |m| m["name"] }).to eq(%w[Gemma-4B-it other])
      expect(payload["models"].first).to eq("name" => "Gemma-4B-it", "host" => nil, "id" => "Gemma-4B-it")
    end

    it "answers with the other hosts and a warning when a host is down" do
      registry = FakeModelRegistry.new({
        "default" => { models: [model_info("Gemma-4B-it")], error: nil },
        "cloud" => { models: [], error: "connection refused" }
      })

      payload = models_payload(registry)

      expect(payload["models"].map { |m| m["name"] }).to eq(%w[Gemma-4B-it])
      expect(payload["warning"]).to eq("cloud: connection refused")
    end

    it "answers the default alone with a warning when the registry fails" do
      payload = models_payload(FakeModelRegistry.new(RuntimeError.new("no config")))

      expect(payload).to eq("default" => "Gemma-4B-it", "models" => [{ "name" => "Gemma-4B-it", "host" => nil, "id" => "Gemma-4B-it" }],
                            "warning" => "no config")
    end

    it "does not wait past its deadline: a slow listing answers the last cached lists, or the default alone" do
      slow = FakeModelRegistry.new({ "default" => { models: [model_info("late")], error: nil } }, delay: 1)
      started = mono
      payload = models_payload(slow, models_wait_timeout: 0.05)

      expect(mono - started).to be < 0.5
      expect(payload["models"].map { |m| m["name"] }).to eq(%w[Gemma-4B-it])
      expect(payload["warning"]).to eq("the hosts are still listing their models")

      cached = FakeModelRegistry.new({ "default" => { models: [model_info("late")], error: nil } }, delay: 1,
                                     cached: { "default" => { models: [model_info("Gemma-4B-it"), model_info("old")], error: nil } })
      payload = models_payload(cached, models_wait_timeout: 0.05)
      expect(payload["models"].map { |m| m["name"] }).to eq(%w[Gemma-4B-it old])
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

    # Assets revalidate on every load (no max-age), so a gem upgrade + chi web
    # restart reaches the browser at once, ES-module imports included; the
    # ETag keeps an unchanged asset a bodyless 304.
    it "serves assets with no-cache and a content ETag, 304 when it still matches" do
      app = build_app
      %w[/assets/app.js /assets/turn_view.js].each do |path|
        status, headers, body = app.call(env_for(path))
        expect(status).to eq(200)
        expect(headers["Cache-Control"]).to eq("no-cache")
        etag = headers["ETag"]
        expect(etag).to match(/\A"[0-9a-f]{32}"\z/)
        expect(body.first.bytesize).to eq(headers["Content-Length"].to_i)

        status, headers, body = app.call(env_for(path, headers: { "HTTP_IF_NONE_MATCH" => etag }))
        expect([status, headers["ETag"], headers["Cache-Control"], body]).to eq([304, etag, "no-cache", []])
        expect(app.call(env_for(path, headers: { "HTTP_IF_NONE_MATCH" => %(W/#{etag}, "x") }))[0]).to eq(304)
        expect(app.call(env_for(path, headers: { "HTTP_IF_NONE_MATCH" => '"stale"' }))[0]).to eq(200)
      end
      expect(app.call(env_for("/assets/app.js"))[1]["ETag"]).not_to eq(app.call(env_for("/assets/turn_view.js"))[1]["ETag"])
    end

    it "tells the page where the sessions are stored, ~ for the home folder" do
      status, _headers, body = build_app(state_dir: File.join(Dir.home, "st<a>", "sessions")).call(env_for("/"))

      expect(status).to eq(200)
      expect(body.first).to include('<body data-sessions-dir="~/st&lt;a&gt;/sessions" ')
      expect(body.first).not_to include(".local/state")
    end

    # The turn view is the default; web.view picks stage; ?view=turn|stage
    # overrides it for one page load, anything else (the chat view's
    # ?view=chat too) is ignored.
    it "tells the page its view: turn by default, the config's, or ?view= for one page load" do
      page = ->(path, **opts) { build_app(**opts).call(env_for(path))[2].first }

      expect(page.call("/")).to include(' data-view="turn"')
      %w[turn stage].each do |view|
        expect(page.call("/", view: view)).to include(%( data-view="#{view}"))
        expect(page.call("/?view=#{view}")).to include(%( data-view="#{view}"))
        expect(page.call("/?view=#{view}", view: "stage")).to include(%( data-view="#{view}"))
      end
      expect(page.call("/?view=nope")).to include(' data-view="turn"')
      expect(page.call("/?view=chat")).to include(' data-view="turn"')
      expect(page.call("/?view=chat", view: "stage")).to include(' data-view="stage"')
      expect(page.call("/")).not_to include("data-turn-view")
    end

    # The page parses them (annotate_presets.js); an empty one is kept so
    # it means "none", not the default.
    it "hands the page the annotate presets, escaped, empty kept, a list joined" do
      page = ->(**opts) { build_app(**opts).call(env_for("/"))[2].first }

      expect(page.call).to include(' data-annotate-presets="Agreed|Could you please elaborate?"')
      expect(page.call(annotate_presets: %(Say "hi" & <b>|No))).to include(' data-annotate-presets="Say &quot;hi&quot; &amp; &lt;b&gt;|No"')
      expect(page.call(annotate_presets: "")).to include(' data-annotate-presets=""')
      expect(page.call(annotate_presets: %w[Agreed Why?])).to include(' data-annotate-presets="Agreed|Why?"')
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

    # The browser's cursor names its worker; the Bridge, not the proxy,
    # decides whether it replays or resets.
    it "forwards an epoch-bearing Last-Event-ID unchanged" do
      raw = capture_bridge_request(headers: { "HTTP_LAST_EVENT_ID" => "25-1a2b3c4d" }, query: "?from_seq=0")
      expect(raw).to include("Last-Event-ID: 25-1a2b3c4d\r\n")
    end

    it "omits the header when the client sent no Last-Event-ID" do
      raw = capture_bridge_request(headers: {})
      expect(raw).not_to include("Last-Event-ID")
      expect(raw).to include("GET /session/s1/stream HTTP/1.1")
    end

    # rackup's WEBrick joins every request thread before `run` returns, so a
    # proxy blocked on a quiet bridge would hang Ctrl-C of chi web.
    context "with a bridge that sends its headers, one frame, then stays quiet" do
      let(:server) { TCPServer.new("127.0.0.1", 0) }
      let(:upstream) { Queue.new }

      before do
        @accepter = Thread.new do
          conn = server.accept
          conn.readpartial(16_384)
          conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nid: 1\r\ndata: {}\r\n\r\n")
          upstream << conn
          sleep
        end
        @accepter.report_on_exception = false
      end

      after do
        @accepter.kill
        server.close
      end

      def proxy_for(running)
        described_class::ProxyStreamBody.new(host: "127.0.0.1", port: server.local_address.ip_port, session_id: "s1",
                                             query: "", headers: {}, server_running: -> { running[0] })
      end

      it "ends the body within a second of the server leaving :Running, and closes the bridge socket" do
        running = [true]
        chunks = Queue.new
        reader = Thread.new { proxy_for(running).each { |chunk| chunks << chunk } }
        expect(chunks.pop(timeout: 2)).to eq("id: 1\r\ndata: {}\r\n\r\n")
        conn = upstream.pop(timeout: 2)

        running[0] = false
        started = mono

        expect(reader.join(1.5)).to eq(reader), "the proxy was still reading 1.5 s after shutdown"
        expect(mono - started).to be < 1.2
        expect(conn.wait_readable(1)).to be_truthy
        expect(conn.read_nonblock(1, exception: false)).to be_nil # EOF: the proxy closed its end
      ensure
        reader&.kill
      end

      it "keeps a quiet stream open while the server is running, and forwards what comes next unchanged" do
        running = [true]
        chunks = Queue.new
        reader = Thread.new { proxy_for(running).each { |chunk| chunks << chunk } }
        chunks.pop(timeout: 2)
        conn = upstream.pop(timeout: 2)

        sleep 1.5 # several poll intervals of silence
        expect(reader).to be_alive

        conn.write(": ping\r\n\r\n")
        expect(chunks.pop(timeout: 2)).to eq(": ping\r\n\r\n")
        conn.close
        expect(reader.join(2)).to eq(reader) # the bridge's close still ends it
      ensure
        reader&.kill
      end
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

    it "names each session's owner (worker, tui or none) in the list and the session view" do
      worker, tui, free = %w[idle idle idle].map { |st| saved_session(st) }
      locks = { worker => "worker", tui => "tui" }.map do |session, kind|
        Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), kind: kind)
      end
      allow(app).to receive(:bridge_get_json).and_return(nil)
      allow(app).to receive(:bridge_event_seq).and_return(nil)

      _, _, list = app.call(env_for("/api/sessions"))
      owners = JSON.parse(list.first).to_h { |s| [s["id"], s["owner"]] }
      _, _, show = app.call(env_for("/api/sessions/#{tui.id}"))

      expect(owners).to eq(worker.id => "worker", tui.id => "tui", free.id => nil)
      expect(JSON.parse(show.first).dig("session", "owner")).to eq("tui")
    ensure
      locks&.each(&:release)
    end

    it "gives each session in the list its recap's first sentence" do
      with, without = %w[idle idle].map { |st| saved_session(st) }
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(with.id, state_dir: state_dir))
      File.write(File.join(Samagotchi::Session.session_dir(with.id, state_dir: state_dir), "recap.json"),
                 JSON.generate(text: "We fixed the login. Then the tests.", covered: 2))
      allow(app).to receive(:bridge_get_json).and_return(nil)
      allow(app).to receive(:bridge_event_seq).and_return(nil)

      _, _, list = app.call(env_for("/api/sessions"))

      expect(JSON.parse(list.first).to_h { |s| [s["id"], s["recap"]] }).to eq(with.id => "We fixed the login.", without.id => nil)
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

    it "falls back to the input file when the bridge closes before the post" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(app).to receive(:live_bridge_client).and_return(bridge)
      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)
      expect(manager).to receive(:write_turn_input).and_return(true)

      status, _headers, body = app.call(env_for("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(202)
      expect(JSON.parse(body.first)).to include("status" => "accepted")
    end

    it "answers 504 and queues no file when the bridge times out" do
      manager = FakeResponsesManager.new
      app = build_app(manager: manager, state_dir: Dir.mktmpdir)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(app).to receive(:live_bridge_client).and_return(bridge)
      allow(bridge).to receive(:post_turn).and_raise(Errno::ETIMEDOUT)
      expect(manager).not_to receive(:write_turn_input)

      status, _headers, body = app.call(env_for("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(504)
      expect(JSON.parse(body.first)).to include("error" => "worker_timeout", "detail" => /message was not sent/)
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

  describe "a session another process owns (TUI or worker)" do
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

    it "wakes a worker when the one it found idle-exits before the write" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Process).to receive(:spawn).and_return(50_005)
      # The worker leaves between the resume (which saw it) and the write.
      allow(app).to receive(:live_bridge_client) do
        @lock.release
        nil
      end

      status, _headers, _body = app.call(env_for("/api/sessions/#{session.id}/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(202)
      expect(Process).to have_received(:spawn).once
      expect(input_files.size).to eq(1)
    end

    it "leaves a live worker to read the file" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Process).to receive(:spawn)
      allow(app).to receive(:live_bridge_client).and_return(nil)

      status, _headers, _body = app.call(env_for("/api/sessions/#{session.id}/turn", method: "POST", body: '{"prompt":"hi"}'))

      expect(status).to eq(202)
      expect(Process).not_to have_received(:spawn)
    end

    it "waits (bounded) for the worker to let go on POST /stop, so a resume after it spawns a fresh one" do
      allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(true)

      status, _headers, _body = app.call(env_for("/api/sessions/#{session.id}/stop", method: "POST"))

      expect(status).to eq(200)
      expect(Samagotchi::SessionManager).to have_received(:stop_session)
        .with(session.id, state_dir: state_dir, wait: Samagotchi::Web::App::STOP_WAIT_SECONDS)
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

    describe "POST /api/sessions/:id/archive and /unarchive" do
      def archived? = Samagotchi::ArchiveStore.archived?(session_dir)

      it "archives, and the list still carries it, marked archived (the page filters at render)" do
        status, _headers, body = app.call(env_for("/api/sessions/#{session.id[0, 8]}/archive", method: "POST"))

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq("status" => "archived", "session_id" => session.id, "archived" => [session.id],
                                             "stopped" => [], "discarded" => [])
        expect(archived?).to be(true)
        _status, _headers, list = app.call(env_for("/api/sessions"))
        expect(JSON.parse(list.first).map { |s| [s["id"], s["archived"]] }).to eq([[session.id, true]])

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/unarchive", method: "POST"))
        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq("status" => "unarchived", "session_id" => session.id, "unarchived" => [session.id])
        expect(archived?).to be(false)
      end

      it "stops a live idle worker first (bounded wait)" do
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
        allow(Samagotchi::SessionManager).to receive(:stop_session) do
          @lock.release
          true
        end

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/archive", method: "POST"))

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to include("stopped" => [session.id])
        expect(Samagotchi::SessionManager).to have_received(:stop_session)
          .with(session.id, state_dir: state_dir, wait: Samagotchi::Web::App::STOP_WAIT_SECONDS)
        expect(archived?).to be(true)
      end

      it "answers 409 busy while a turn runs, owned_by_tui for a REPL's, and archives nothing" do
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
        Samagotchi::Session.mark_running(session.id, state_dir: state_dir)

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/archive", method: "POST"))
        expect(status).to eq(409)
        expect(JSON.parse(body.first)).to include("error" => "busy")

        @lock.release
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/archive", method: "POST"))
        expect(status).to eq(409)
        expect(JSON.parse(body.first)).to include("error" => "owned_by_tui")
        expect(archived?).to be(false)
      end

      it "answers 409 scratch for a chi scratch session, 404 for an unknown one" do
        session.scratch = true
        session.save(state_dir: state_dir)

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}/archive", method: "POST"))
        expect(status).to eq(409)
        expect(JSON.parse(body.first)).to include("error" => "scratch",
                                                  "detail" => "a scratch session is deleted when you leave; nothing to archive")

        status, = app.call(env_for("/api/sessions/nope/archive", method: "POST"))
        expect(status).to eq(404)
        status, = app.call(env_for("/api/sessions/nope/unarchive", method: "POST"))
        expect(status).to eq(404)
      end
    end

    describe "DELETE /api/sessions/:id" do
      let(:session_file) { File.join(state_dir, "#{session.id}.json") }

      it "deletes the session's file and directory" do
        FileUtils.mkdir_p(File.join(session_dir, "notes"))

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}", method: "DELETE"))

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to eq("status" => "deleted", "session_id" => session.id, "stopped" => false)
        expect(File.exist?(session_file)).to be false
        expect(Dir.exist?(session_dir)).to be false
      end

      it "stops a live worker first (bounded wait), then deletes" do
        allow(Samagotchi::SessionManager).to receive(:delete_session).and_call_original
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
        allow(Samagotchi::SessionManager).to receive(:stop_session) do
          @lock.release
          true
        end

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}", method: "DELETE"))

        expect(status).to eq(200)
        expect(JSON.parse(body.first)).to include("stopped" => true)
        expect(Samagotchi::SessionManager).to have_received(:delete_session)
          .with(session.id, state_dir: state_dir, stop: true, wait: Samagotchi::Web::App::STOP_WAIT_SECONDS)
        expect(File.exist?(session_file)).to be false
      end

      it "answers 409 when the worker is still shutting down, and keeps the session" do
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
        allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(false)

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}", method: "DELETE"))

        expect(status).to eq(409)
        expect(JSON.parse(body.first)).to include("error" => "still_stopping")
        expect(File.exist?(session_file)).to be true
      end

      it "answers 409 for a session a chi REPL has open, and signals nothing" do
        @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
        allow(Process).to receive(:kill)

        status, _headers, body = app.call(env_for("/api/sessions/#{session.id}", method: "DELETE"))

        expect(status).to eq(409)
        expect(JSON.parse(body.first)).to include("error" => "owned_by_tui",
                                                  "detail" => "session #{session.id} is open in a chi REPL; close it there first")
        expect(Process).not_to have_received(:kill)
        expect(File.exist?(session_file)).to be true
      end

      it "answers 404 for an unknown session" do
        status, _headers, body = app.call(env_for("/api/sessions/nope", method: "DELETE"))

        expect(status).to eq(404)
        expect(JSON.parse(body.first)).to include("error" => "not_found")
      end
    end
  end

  describe "POST /api/sessions/:id/cancel" do
    it "passes a known reason through and echoes it; anything else is manual" do
      app = build_app(state_dir: Dir.mktmpdir)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(app).to receive(:bridge_client).with("s1").and_return(bridge)
      sent = []
      allow(bridge).to receive(:cancel) do |reason:|
        sent << reason
        Samagotchi::BridgeClient::Response.new(status: 202, body: nil)
      end

      replies = ['{"reason":"ctrl_c"}', '{"reason":"<img src=x onerror=alert(1)>"}', "{}", ""].map do |body|
        _status, _headers, out = app.call(env_for("/api/sessions/s1/cancel", method: "POST", body: body))
        JSON.parse(out.first)["reason"]
      end

      expect(replies).to eq(%w[ctrl_c manual user user])
      expect(sent).to eq(%w[ctrl_c manual user user])
    end

    it "takes a POST with no body and no Content-Length as empty (curl -X POST)" do
      app = build_app(state_dir: Dir.mktmpdir)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(app).to receive(:bridge_client).with("s1").and_return(bridge)
      allow(bridge).to receive(:cancel).with(reason: "user")
                                       .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: nil))
      # WEBrick (through rackup) refuses to read such a body: LengthRequired.
      input = Object.new
      def input.read(*) = raise("LengthRequired")
      env = env_for("/api/sessions/s1/cancel", method: "POST")
      env.delete("CONTENT_LENGTH")
      env["rack.input"] = input

      status, _headers, out = app.call(env)

      expect(status).to eq(202)
      expect(JSON.parse(out.first)["reason"]).to eq("user")
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

  describe "POST /api/sessions/:id/question/dismiss" do
    # A one-request Bridge: answers with +status_line+ and +reply+, and
    # records the request it got.
    def serve_bridge_once(status_line, reply)
      server = TCPServer.new("127.0.0.1", 0)
      received = +""
      thread = Thread.new do
        conn = server.accept
        received << conn.readpartial(16_384) until received.include?("\r\n\r\n") && received.end_with?("}")
        conn.write("HTTP/1.1 #{status_line}\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
        conn.close
      end
      thread.report_on_exception = false
      [server, thread, received]
    end

    def dismiss(app, body = '{"id":"q-3"}')
      status, _headers, resp = app.call(env_for("/api/sessions/s1/question/dismiss", method: "POST", body: body))
      [status, JSON.parse(resp.first)]
    end

    def app_with_bridge(port)
      build_app(state_dir: Dir.mktmpdir).tap { |app| allow(app).to receive(:bridge_sidecar_port).and_return(port) }
    end

    it "returns 400 without a question id, and 503 with no live bridge" do
      expect(dismiss(app_with_bridge(nil), "{}")).to match([400, hash_including("error" => "missing_fields")])
      expect(dismiss(app_with_bridge(nil))).to match([503, hash_including("error" => "not_live")])
    end

    it "proxies the dismiss to the live bridge" do
      server, thread, received = serve_bridge_once("200 OK", '{"status":"dismissed","id":"q-3"}')

      status, resp = dismiss(app_with_bridge(server.local_address.ip_port))
      thread.join(1)
      server.close

      expect(status).to eq(200)
      expect(resp).to include("status" => "dismissed", "id" => "q-3")
      expect(received).to start_with("POST /session/s1/question/dismiss HTTP/1.1").and include('{"id":"q-3","deadline":')
    end

    it "passes the bridge's 409 through when the question is no longer pending" do
      server, thread, = serve_bridge_once("409 Conflict", '{"error":"question_not_pending","detail":"no pending question q-3"}')

      status, resp = dismiss(app_with_bridge(server.local_address.ip_port))
      thread.join(1)
      server.close

      expect(status).to eq(409)
      expect(resp).to include("error" => "question_not_pending")
    end

    it "says so when the session's worker is older than the route" do
      server, thread, = serve_bridge_once("404 Not Found", '{"error":"not_found"}')

      status, resp = dismiss(app_with_bridge(server.local_address.ip_port))
      thread.join(1)
      server.close

      expect(status).to eq(501)
      expect(resp).to include("error" => "not_supported")
      expect(resp["detail"]).to match(/restart it: chi sessions stop \S+ && chi --resume \S+/)
    end
  end

  describe "POST /api/sessions/:id/command" do
    def serve_bridge_once(status_line, reply)
      server = TCPServer.new("127.0.0.1", 0)
      received = +""
      thread = Thread.new do
        conn = server.accept
        received << conn.readpartial(16_384) until received.include?("\r\n\r\n") && received.end_with?("}")
        conn.write("HTTP/1.1 #{status_line}\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
        conn.close
      end
      thread.report_on_exception = false
      [server, thread, received]
    end

    def command(app, body = '{"line":"/model x","client_id":"web:1"}')
      status, _headers, resp = app.call(env_for("/api/sessions/s1/command", method: "POST", body: body))
      [status, JSON.parse(resp.first)]
    end

    def app_with_bridge(port, manager: FakeResponsesManager.new)
      build_app(manager: manager, state_dir: Dir.mktmpdir).tap { |app| allow(app).to receive(:bridge_sidecar_port).and_return(port) }
    end

    it "wakes the session's worker and hands the command to its Bridge" do
      manager = FakeResponsesManager.new
      server, thread, received = serve_bridge_once("202 Accepted", '{"status":"accepted","command_id":"c1","session_id":"s1"}')

      status, resp = command(app_with_bridge(server.local_address.ip_port, manager: manager))
      thread.join(1)
      server.close

      expect(status).to eq(202)
      expect(resp).to include("command_id" => "c1")
      expect(manager.resume_calls.map(&:first)).to eq(["s1"])
      expect(received).to start_with("POST /session/s1/command HTTP/1.1").and include('{"line":"/model x","client_id":"web:1","deadline":')
    end

    it "returns 400 without a line, and 503 with no live bridge" do
      expect(command(app_with_bridge(nil), "{}")).to match([400, hash_including("error" => "missing_fields")])
      expect(command(app_with_bridge(nil))).to match([503, hash_including("error" => "not_live")])
    end

    it "passes the Bridge's 400 through for a line that isn't a session command" do
      server, thread, = serve_bridge_once("400 Bad Request", '{"error":"unknown_command","detail":"not a session command: /nope"}')

      status, resp = command(app_with_bridge(server.local_address.ip_port), '{"line":"/nope"}')
      thread.join(1)
      server.close

      expect(status).to eq(400)
      expect(resp).to include("error" => "unknown_command", "detail" => "not a session command: /nope")
    end

    it "says so when the session's worker is older than the route" do
      server, thread, = serve_bridge_once("404 Not Found", '{"error":"not_found"}')

      status, resp = command(app_with_bridge(server.local_address.ip_port))
      thread.join(1)
      server.close

      expect(status).to eq(501)
      expect(resp).to include("error" => "not_supported")
      expect(resp["detail"]).to match(/restart it: chi sessions stop \S+ && chi --resume \S+/)
    end

    it "answers 409 while a plain chi owns the session" do
      manager = FakeResponsesManager.new
      def manager.resume_session(id, state_dir: nil) = raise(Samagotchi::SessionManager::OwnedByTUI, id)

      expect(command(app_with_bridge(nil, manager: manager))).to match([409, hash_including("error" => "owned_by_tui")])
    end
  end

  # A worker frozen (a sleeping Mac, SIGSTOP) or too slow: the client's read
  # timed out, or the Bridge read the request after its deadline and dropped
  # it. Either way it didn't run, and the page says so.
  describe "a command, answer or dismissal the worker didn't take in time" do
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }
    let(:late) { Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}') }
    let(:app) do
      build_app(manager: FakeResponsesManager.new, state_dir: Dir.mktmpdir).tap do |app|
        allow(app).to receive_messages(live_bridge_client: bridge, bridge_client: bridge)
      end
    end

    def post(path, body)
      status, _headers, resp = app.call(env_for("/api/sessions/s1/#{path}", method: "POST", body: body))
      [status, JSON.parse(resp.first)]
    end

    {
      "a command" => ["command", '{"line":"!echo hi"}', :post_command, "the command was not run"],
      "an answer" => ["answer", '{"id":"q-1","selected":["A"]}', :answer, "the answer was not sent"],
      "a dismissal" => ["question/dismiss", '{"id":"q-1"}', :dismiss_question, "the question was not dismissed"]
    }.each do |what, (path, body, call, said)|
      it "answers 504 for #{what} the worker timed out on" do
        allow(bridge).to receive(call).and_raise(Errno::ETIMEDOUT)

        expect(post(path, body)).to eq([504, { "error" => "worker_timeout",
                                               "detail" => "the session's worker did not answer, so #{said}" }])
      end

      it "answers 504 for #{what} the worker dropped as past its deadline" do
        allow(bridge).to receive(call).and_return(late)

        expect(post(path, body)).to eq([504, { "error" => "worker_timeout",
                                               "detail" => "the session's worker did not answer, so #{said}" }])
      end
    end
  end
end
