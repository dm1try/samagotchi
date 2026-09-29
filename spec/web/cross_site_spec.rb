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
end
