# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/session_hub"
require "samagotchi/web/token"
require "samagotchi/session"

# chi web on the LAN (web.host: lan): every route answers a phone only
# with the access token (the chi_token cookie, a Bearer header, or once as
# ?token= on the page, which trades it for the cookie). A loopback peer
# (this Mac: the desktop browser, chi's own tools) needs none.
RSpec.describe Samagotchi::Web::App, "LAN access token" do
  let(:token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" } # 43 characters, like a real one
  let(:lan_ip) { "192.168.1.55" }
  let(:phone) { "192.168.1.20" }

  let(:state_dir) { Dir.mktmpdir("web-lan") }
  let(:public_dir) do
    Dir.mktmpdir("web-lan-public").tap do |dir|
      File.write(File.join(dir, "index.html"), "<html>chi</html>")
      File.write(File.join(dir, "app.js"), "// app")
    end
  end
  let(:manager) do
    Class.new do
      def retention_sweep_if_due(**) = nil
    end.new
  end
  let(:lan) { { ip: lan_ip, token: token } }
  let(:app) do
    described_class.new(manager: manager, state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, lan: lan,
                        hub: Samagotchi::Web::SessionHub.new(state_dir: state_dir))
  end

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(public_dir)
  end

  def call(path, method: "GET", host: "#{lan_ip}:4567", peer: phone, headers: {})
    env = Rack::MockRequest.env_for(path, method: method, **headers)
    env["HTTP_HOST"] = host
    env["REMOTE_ADDR"] = peer
    status, headers, chunks = app.call(env)
    text = +""
    chunks.each { |c| text << c } if chunks.respond_to?(:each) && !headers["Content-Type"].to_s.start_with?("text/event-stream")
    [status, headers, text]
  end

  def cookie(value = token) = { "HTTP_COOKIE" => "other=1; chi_token=#{value}" }

  describe "a LAN peer without the token" do
    it "gets a 401 JSON for the API" do
      status, headers, body = call("/api/sessions")

      expect(status).to eq(401)
      expect(headers["Content-Type"]).to start_with("application/json")
      expect(JSON.parse(body)["error"]).to eq("unauthorized")
    end

    it "gets a 401 page that says how to get in, with a field to paste the token" do
      status, headers, body = call("/")

      expect(status).to eq(401)
      expect(headers["Content-Type"]).to start_with("text/html")
      expect(body).to include("scan its QR").and include('name="token"')
      expect(body).not_to include(token)
    end

    it "is refused on every route: the event streams, static files and /api/info" do
      %w[/api/sessions/0123456789abcdef/stream /api/events /app.js /index.html /api/info /nope].each do |path|
        expect(call(path).first).to eq(401), path
      end
      expect(call("/api/sessions", method: "POST").first).to eq(401)
    end

    it "gets a 401 for a wrong token, in any form" do
      expect(call("/api/info", headers: cookie("wrong")).first).to eq(401)
      expect(call("/api/info", headers: { "HTTP_AUTHORIZATION" => "Bearer wrong" }).first).to eq(401)
      expect(call("/?token=wrong").first).to eq(401)
      expect(call("/api/info", headers: cookie("")).first).to eq(401)
    end

    it "still gets a 401 with X-Forwarded-For: 127.0.0.1 (the peer is the socket's address)" do
      expect(call("/api/info", headers: { "HTTP_X_FORWARDED_FOR" => "127.0.0.1" }).first).to eq(401)
      expect(call("/api/info", headers: { "HTTP_X_REAL_IP" => "127.0.0.1" }).first).to eq(401)
    end

    it "gets nothing when the token file is gone" do
      app = described_class.new(manager: manager, state_dir: state_dir, public_dir: public_dir, lan: { ip: lan_ip, token: nil })
      env = Rack::MockRequest.env_for("/api/info", "HTTP_AUTHORIZATION" => "Bearer ")
      env["HTTP_HOST"] = "#{lan_ip}:4567"
      env["REMOTE_ADDR"] = phone
      expect(app.call(env).first).to eq(401)
    end
  end

  describe "the token link" do
    it "trades ?token= for the cookie and a 303 to the same page without it" do
      status, headers, = call("/?dir=/work/repo&token=#{token}")

      expect(status).to eq(303)
      expect(headers["Location"]).to eq("/?dir=/work/repo")
      expect(headers["Set-Cookie"]).to eq("chi_token=#{token}; HttpOnly; SameSite=Lax; Path=/; Max-Age=34560000")
      expect(headers["Cache-Control"]).to eq("no-store")
    end

    it "sends the bare page when the token was the only parameter" do
      expect(call("/index.html?token=#{token}")[1]["Location"]).to eq("/index.html")
    end
  end

  describe "a LAN peer with the token" do
    it "passes with the cookie" do
      expect(call("/api/sessions", headers: cookie).first).to eq(200)
      expect(call("/", headers: cookie).first).to eq(200)
      expect(call("/app.js", headers: cookie).first).to eq(200)
    end

    it "passes with a Bearer header (curl from another machine)" do
      expect(call("/api/info", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" }).first).to eq(200)
    end

    it "is still held to the cross-site check" do
      status, = call("/api/sessions", method: "POST", headers: cookie.merge("HTTP_ORIGIN" => "https://evil.example"))
      expect(status).to eq(403)
    end

    it "takes the token the server has now (a Token::Source), not the one it started with" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "web-token")
        old = Samagotchi::Web::Token.load_or_create(path)
        app = described_class.new(manager: manager, state_dir: state_dir, public_dir: public_dir,
                                  lan: { ip: lan_ip, token: Samagotchi::Web::Token::Source.new(path) })
        request = lambda do |value|
          env = Rack::MockRequest.env_for("/api/info", "HTTP_AUTHORIZATION" => "Bearer #{value}")
          env["HTTP_HOST"] = "#{lan_ip}:4567"
          env["REMOTE_ADDR"] = phone
          app.call(env).first
        end
        expect(request.call(old)).to eq(200)

        new = Samagotchi::Web::Token.rotate(path)
        expect(request.call(old)).to eq(401)
        expect(request.call(new)).to eq(200)
      end
    end
  end

  describe "a loopback peer" do
    it "needs no token, on any loopback address" do
      %w[127.0.0.1 ::1 ::ffff:127.0.0.1].each do |peer|
        expect(call("/api/sessions", host: "127.0.0.1:4567", peer: peer).first).to eq(200), peer
        expect(call("/", host: "127.0.0.1:4567", peer: peer).first).to eq(200), peer
      end
    end

    it "is not exempt when it reaches the LAN address (that peer is the LAN IP, not loopback)" do
      expect(call("/api/info", peer: lan_ip).first).to eq(401)
    end

    it "sees the LAN address in /api/info" do
      _, _, body = call("/api/info", host: "127.0.0.1:4567", peer: "127.0.0.1")
      expect(JSON.parse(body)["lan"]).to eq(lan_ip)
    end
  end

  describe "the Host header" do
    it "takes the LAN address in LAN mode" do
      expect(call("/api/info", host: lan_ip, headers: cookie).first).to eq(200)
      expect(call("/api/info", host: "#{lan_ip}:4567", headers: cookie).first).to eq(200)
    end

    it "refuses any other name, before the token is looked at (DNS rebinding)" do
      %w[192.168.1.56:4567 evil.example mac.local:4567].each do |host|
        expect(call("/api/info", host: host, headers: cookie).first).to eq(403), host
      end
      expect(JSON.parse(call("/api/info", host: "evil.example")[2])["detail"])
        .to eq("only the host names 127.0.0.1, [::1], localhost and 192.168.1.55 are answered")
    end

    it "refuses the LAN address in loopback mode" do
      app = described_class.new(manager: manager, state_dir: state_dir, public_dir: public_dir)
      env = Rack::MockRequest.env_for("/api/info")
      env["HTTP_HOST"] = "#{lan_ip}:4567"
      env["REMOTE_ADDR"] = "127.0.0.1"
      expect(app.call(env).first).to eq(403)
    end
  end

  describe "loopback mode" do
    let(:lan) { nil }

    it "asks no token of anyone and says lan: null" do
      expect(call("/api/info", host: "127.0.0.1:4567", peer: phone).first).to eq(200)
      expect(JSON.parse(call("/api/info", host: "127.0.0.1:4567", peer: "127.0.0.1")[2])).to include("lan" => nil)
    end
  end

  describe "the log" do
    it "warns of a refused peer at most once a minute per peer" do
      allow(Samagotchi::Log).to receive(:warn)
      now = 1000.0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }

      3.times { call("/api/info") }
      call("/api/info", peer: "192.168.1.21")
      now += 61
      call("/app.js")

      expect(Samagotchi::Log).to have_received(:warn).with(:web, "unauthorized", peer: phone, path: "/api/info").once
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "unauthorized", peer: "192.168.1.21", path: "/api/info").once
      expect(Samagotchi::Log).to have_received(:warn).with(:web, "unauthorized", peer: phone, path: "/app.js").once
    end
  end
end
