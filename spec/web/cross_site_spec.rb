# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"

# The web server listens on 127.0.0.1, and any page open in the desktop
# browser can talk to it. These specs pin the gate in front of every route:
# the Host header (DNS rebinding) and the request's origin (other websites).
RSpec.describe Samagotchi::Web::App, "cross-site gate" do
  let(:state_dir) { Dir.mktmpdir("web-cross-site") }
  let(:project) { Dir.mktmpdir("web-cross-site-project") }
  let(:manager) do
    Class.new do
      attr_reader :spawn_calls, :deleted

      def initialize
        @spawn_calls = []
        @deleted = []
      end

      def spawn_session(prompt:, state_dir: nil, **kw)
        @spawn_calls << { prompt: prompt, **kw }
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      end

      def list_sessions(**) = []
      def retention_sweep_if_due(**) = nil
      def stop_session(*, **) = nil
      def delete_session(id, **) = @deleted << id
    end.new
  end
  let(:app) do
    described_class.new(manager: manager, state_dir: state_dir, bridge_wait_timeout: 0)
  end

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(project)
  end

  def call(path, method: "GET", host: "127.0.0.1:4567", body: nil, headers: {})
    env = Rack::MockRequest.env_for(path, method: method, input: body, **headers)
    host.nil? ? env.delete("HTTP_HOST") : env["HTTP_HOST"] = host
    status, headers, chunks = app.call(env)
    text = +""
    chunks.each { |c| text << c } if chunks.respond_to?(:each) && !headers["Content-Type"].to_s.start_with?("text/event-stream")
    [status, headers, text]
  end

  def create_body
    JSON.generate(prompt: "run rm -rf ~", dir: project)
  end

  describe "the Host header" do
    it "answers the loopback names with any port, [::1] in brackets included" do
      %w[127.0.0.1 127.0.0.1:4567 localhost localhost:4567 LOCALHOST:1 [::1] [::1]:4567].each do |host|
        expect(call("/api/info", host: host).first).to eq(200), host
      end
    end

    it "refuses any other name (DNS rebinding)" do
      %w[evil.example evil.example:4567 127.0.0.1.evil.example 192.168.1.55:4567 ::1].each do |host|
        expect(call("/api/info", host: host).first).to eq(403), host
      end
    end

    it "reads the raw Host, so X-Forwarded-Host can't pass a foreign name" do
      status, = call("/api/info", host: "evil.example", headers: { "HTTP_X_FORWARDED_HOST" => "127.0.0.1" })
      expect(status).to eq(403)
    end

    it "answers a request with no Host from a loopback peer (HTTP/1.0 clients)" do
      expect(call("/api/info", host: nil, headers: { "REMOTE_ADDR" => "127.0.0.1" }).first).to eq(200)
      expect(call("/api/info", host: nil, headers: { "REMOTE_ADDR" => "192.168.1.20" }).first).to eq(403)
    end
  end

  describe "requests from other websites" do
    it "refuses a cross-site text/plain POST that would start a session, before it reaches the manager" do
      status, _, body = call("/api/sessions", method: "POST", body: create_body,
                                              headers: { "CONTENT_TYPE" => "text/plain", "HTTP_ORIGIN" => "https://evil.example",
                                                         "HTTP_SEC_FETCH_SITE" => "cross-site" })
      expect(status).to eq(403)
      expect(JSON.parse(body)["error"]).to eq("cross_origin")
      expect(manager.spawn_calls).to be_empty
    end

    it "refuses a POST from an older browser that sends only Origin" do
      status, = call("/api/sessions", method: "POST", body: create_body,
                                      headers: { "CONTENT_TYPE" => "text/plain", "HTTP_ORIGIN" => "https://evil.example" })
      expect(status).to eq(403)
      expect(manager.spawn_calls).to be_empty
    end

    it "refuses a POST from another local dev server (same host, another port)" do
      status, = call("/api/sessions", method: "POST", body: create_body,
                                      headers: { "HTTP_ORIGIN" => "http://localhost:8000", "HTTP_SEC_FETCH_SITE" => "same-site" })
      expect(status).to eq(403)
      status, = call("/api/sessions", method: "POST", body: create_body, host: "localhost:4567",
                                      headers: { "HTTP_ORIGIN" => "http://localhost:8000" })
      expect(status).to eq(403)
      expect(manager.spawn_calls).to be_empty
    end

    it "refuses Origin: null (a sandboxed frame or a file:// page), which is foreign, not absent" do
      status, = call("/api/sessions", method: "POST", body: create_body, headers: { "HTTP_ORIGIN" => "null" })
      expect(status).to eq(403)
      expect(manager.spawn_calls).to be_empty
    end

    it "refuses a cross-site DELETE" do
      status, = call("/api/sessions/0123456789abcdef", method: "DELETE",
                                                        headers: { "HTTP_ORIGIN" => "https://evil.example", "HTTP_SEC_FETCH_SITE" => "cross-site" })
      expect(status).to eq(403)
      expect(manager.deleted).to be_empty
    end

    it "refuses a cross-site multipart image upload" do
      status, = call("/api/sessions/0123456789abcdef/images?name=a.png", method: "POST", body: "--x\r\n\r\n--x--\r\n",
                                                                          headers: { "CONTENT_TYPE" => "multipart/form-data; boundary=x",
                                                                                     "HTTP_ORIGIN" => "https://evil.example",
                                                                                     "HTTP_SEC_FETCH_SITE" => "cross-site" })
      expect(status).to eq(403)
    end

    it "refuses cross-site reads of the API, the event stream included" do
      headers = { "HTTP_ORIGIN" => "https://evil.example", "HTTP_SEC_FETCH_SITE" => "cross-site" }
      expect(call("/api/sessions", headers: headers).first).to eq(403)
      expect(call("/api/events", headers: headers).first).to eq(403)
      expect(call("/api/sessions/0123456789abcdef/stream", headers: { "HTTP_SEC_FETCH_SITE" => "cross-site" }).first).to eq(403)
      expect(call("/api/info", headers: { "HTTP_SEC_FETCH_SITE" => "same-site" }).first).to eq(403)
    end

    it "still serves the page to a link followed from another site (a top-level GET)" do
      expect(call("/", headers: { "HTTP_SEC_FETCH_SITE" => "cross-site" }).first).to eq(200)
    end
  end

  describe "the page and local tools" do
    it "accepts a same-origin POST (the page's own fetch)" do
      status, = call("/api/sessions", method: "POST", body: create_body,
                                      headers: { "CONTENT_TYPE" => "application/json", "HTTP_ORIGIN" => "http://127.0.0.1:4567",
                                                 "HTTP_SEC_FETCH_SITE" => "same-origin" })
      expect(status).to eq(201)
      expect(manager.spawn_calls.size).to eq(1)
    end

    it "accepts a same-origin POST on localhost and [::1]" do
      expect(call("/api/sessions", method: "POST", body: create_body, host: "localhost:4567",
                                   headers: { "HTTP_ORIGIN" => "http://localhost:4567" }).first).to eq(201)
      expect(call("/api/sessions", method: "POST", body: create_body, host: "[::1]:4567",
                                   headers: { "HTTP_ORIGIN" => "http://[::1]:4567" }).first).to eq(201)
    end

    it "accepts a same-origin read and a typed-in navigation (Sec-Fetch-Site: none)" do
      expect(call("/api/sessions", headers: { "HTTP_SEC_FETCH_SITE" => "same-origin" }).first).to eq(200)
      expect(call("/api/sessions", headers: { "HTTP_SEC_FETCH_SITE" => "none" }).first).to eq(200)
    end

    it "accepts a POST with no Origin and no Sec-Fetch-Site (curl, Net::HTTP)" do
      status, = call("/api/sessions", method: "POST", body: create_body)
      expect(status).to eq(201)
    end
  end

  describe "CORS" do
    it "sends no Access-Control-Allow-Origin on any response" do
      responses = [
        call("/api/info"),
        call("/api/sessions"),
        call("/api/sessions", method: "POST", body: create_body),
        call("/api/sessions/nope"),
        call("/api/sessions/nope/output"),
        call("/api/sessions/nope/stream"),
        call("/nope"),
        call("/"),
        call("/api/info", host: "evil.example"),
        call("/api/sessions", method: "POST", body: "{}", headers: { "HTTP_ORIGIN" => "null" })
      ]
      responses.each { |status, headers, _| expect(headers.keys.map(&:downcase)).not_to include("access-control-allow-origin"), status.to_s }
    end
  end
end
