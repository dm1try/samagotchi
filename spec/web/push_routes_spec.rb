# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/public_url"
require "samagotchi/web/push"
require_relative "../support/web_push_receiver"

# chi web's Web Push routes (PushRoutes; owner only: participant_gate_spec
# walks every :owner row) and the gate-free files a Home Screen app fetches.
RSpec.describe Samagotchi::Web::App, "push routes" do
  let(:owner_token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:public_host) { "studio.example.ts.net" }
  let(:origin) { "https://#{public_host}" }
  let(:public_url) { Samagotchi::Web::PublicUrl.from_config(url: origin) }
  let(:root) { Dir.mktmpdir("web-push-routes") }
  let(:state_dir) { File.join(root, "samagotchi", "sessions") }
  let(:store) { Samagotchi::Web::Push::Store.new(Samagotchi::Web::Push::Store.dir(state_dir: state_dir)) }
  let(:client) { instance_double(Samagotchi::Web::Push::Client) }
  let(:push) { Samagotchi::Web::Push::Runtime.new(store: store, client: client, origin: origin) }
  # The files the Home Screen app fetches, and two that stay gated.
  let(:public_dir) do
    Dir.mktmpdir("web-push-public").tap do |dir|
      FileUtils.mkdir_p(File.join(dir, "icons"))
      %w[index.html app.js manifest.webmanifest sw.js apple-touch-icon.png icons/chi-180.png icons/chi-192.png
         icons/chi-512.png].each { |path| File.write(File.join(dir, path), "x") }
    end
  end
  let(:app) do
    described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, public_url: public_url,
                        public_token: owner_token, push: push)
  end
  let(:receiver) { WebPushReceiver.new }
  let(:endpoint) { "https://web.push.apple.com/QGphone" }
  let(:iphone) { "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148" }

  after do
    FileUtils.remove_entry(root)
    FileUtils.remove_entry(public_dir)
  end

  def call(path, method: "GET", body: nil, token: owner_token, agent: iphone)
    env = Rack::MockRequest.env_for(path, method: method, input: body && JSON.generate(body))
    env["HTTP_HOST"] = public_host
    env["REMOTE_ADDR"] = "127.0.0.1"
    env["CONTENT_TYPE"] = "application/json" if body
    env["HTTP_USER_AGENT"] = agent
    env["HTTP_AUTHORIZATION"] = "Bearer #{token}" if token
    status, headers, chunks = app.call(env)
    text = +""
    chunks.each { |chunk| text << chunk }
    [status, headers, text]
  end

  def json(path, **)
    status, _, text = call(path, **)
    [status, text.empty? ? nil : JSON.parse(text)]
  end

  describe "GET /api/push" do
    it "gives the key and origin, and this device when the page names its endpoint" do
      status, body = json("/api/push")
      expect(status).to eq(200)
      expect(body).to eq("enabled" => true, "public_key" => Samagotchi::Web::Push::Crypto.public_key_b64(store.vapid_key),
                         "origin" => origin, "this" => nil)

      sub = store.add(receiver.subscription(endpoint), origin: origin, label: "iPhone · 2026-10-24")
      _, body = json("/api/push?endpoint=#{CGI.escape(endpoint)}")
      expect(body["this"]).to eq("id" => sub.id, "label" => "iPhone · 2026-10-24")
    end

    it "says enabled false, with no key, when push is off" do
      off = described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, public_url: public_url, public_token: owner_token)
      env = Rack::MockRequest.env_for("/api/push")
      env["HTTP_HOST"] = public_host
      env["REMOTE_ADDR"] = "127.0.0.1"
      env["HTTP_AUTHORIZATION"] = "Bearer #{owner_token}"
      status, _, chunks = off.call(env)
      expect(status).to eq(200)
      expect(JSON.parse(chunks.join)).to eq("enabled" => false, "public_key" => nil, "origin" => nil, "this" => nil)
      expect(File.exist?(store.key_path)).to be(false)
    end

    it "needs the owner's token" do
      expect(call("/api/push", token: nil).first).to eq(401)
    end
  end

  describe "POST /api/push/subscriptions" do
    it "keeps this device on this origin with chi's own label, and answers no endpoint" do
      status, body = json("/api/push/subscriptions", method: "POST", body: { subscription: receiver.subscription(endpoint) })

      expect(status).to eq(201)
      expect(body.keys).to eq(%w[id label])
      expect(body["label"]).to match(/\AiPhone · \d{4}-\d{2}-\d{2}\z/)
      expect(store.subscriptions.map { |sub| [sub.id, sub.origin] }).to eq([[body["id"], origin]])
    end

    it "labels by the device class" do
      { "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X)" => "iPad", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" => "Mac",
        "Mozilla/5.0 (X11; Linux x86_64)" => "Browser" }.each do |agent, kind|
        _, body = json("/api/push/subscriptions", method: "POST", agent: agent,
                                                  body: { subscription: WebPushReceiver.new.subscription("#{endpoint}#{kind}") })
        expect(body["label"]).to start_with("#{kind} · ")
      end
    end

    it "refuses with the store's one message per condition" do
      bad = receiver.subscription("https://evil.example/x")
      status, body = json("/api/push/subscriptions", method: "POST", body: { subscription: bad })
      expect([status, body["error"]]).to eq([400, "invalid_subscription"])
      expect(body["detail"]).to eq("chi web only pushes to the browsers' push services, not evil.example")

      status, body = json("/api/push/subscriptions", method: "POST", body: { nothing: 1 })
      expect([status, body["detail"]]).to eq([400, "a push subscription needs an endpoint and keys (p256dh, auth)"])
      status, = call("/api/push/subscriptions", method: "POST")
      expect(status).to eq(400)
      expect(store.subscriptions).to eq([])
    end
  end

  describe "DELETE /api/push/subscriptions" do
    it "removes this device (and answers 204 for one it doesn't have)" do
      store.add(receiver.subscription(endpoint), origin: origin, label: "a")
      expect(call("/api/push/subscriptions", method: "DELETE", body: { endpoint: endpoint }).first).to eq(204)
      expect(store.subscriptions).to eq([])
      expect(call("/api/push/subscriptions", method: "DELETE", body: { endpoint: endpoint }).first).to eq(204)
      expect(json("/api/push/subscriptions", method: "DELETE", body: {}).first).to eq(400)
    end
  end

  describe "POST /api/push/test" do
    it "pushes a test to this device, or every one on this origin, and answers each result" do
      phone = store.add(receiver.subscription(endpoint), origin: origin, label: "phone")
      pad = store.add(WebPushReceiver.new.subscription("#{endpoint}2"), origin: origin, label: "pad")
      store.add(WebPushReceiver.new.subscription("#{endpoint}3"), origin: "https://old.example", label: "stale")
      sent = []
      allow(client).to receive(:deliver) do |sub, payload, **opts|
        sent << [sub.id, payload[:body], opts]
        Samagotchi::Web::Push::Client::Result.new(status: sub.id == pad.id ? :gone : :ok, code: sub.id == pad.id ? 410 : 201, ms: 7)
      end

      status, body = json("/api/push/test", method: "POST", body: { endpoint: endpoint })
      expect(status).to eq(200)
      expect(body["devices"]).to eq([{ "id" => phone.id, "label" => "phone", "status" => "ok", "code" => 201, "ms" => 7 }])

      _, body = json("/api/push/test", method: "POST", body: {})
      expect(body["devices"].map { |d| [d["label"], d["status"]] }).to eq([%w[phone ok], %w[pad gone]])
      expect(sent.map(&:first)).to eq([phone.id, phone.id, pad.id])
      expect(sent.first[1]).to eq("test notification")
      expect(store.subscriptions.map(&:label)).to eq(%w[phone stale])
    end
  end

  it "answers 409 push_off on the write routes when push is off" do
    off = described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, public_url: public_url, public_token: owner_token)
    env = Rack::MockRequest.env_for("/api/push/test", method: "POST", input: "{}")
    env["HTTP_HOST"] = public_host
    env["REMOTE_ADDR"] = "127.0.0.1"
    env["HTTP_AUTHORIZATION"] = "Bearer #{owner_token}"
    status, _, chunks = off.call(env)
    expect(status).to eq(409)
    expect(JSON.parse(chunks.join)["error"]).to eq("push_off")
  end

  describe "the Home Screen app's files" do
    %w[/manifest.webmanifest /sw.js /apple-touch-icon.png /icons/chi-180.png /icons/chi-192.png /icons/chi-512.png].each do |path|
      it "serves #{path} without a token" do
        status, headers, = call(path, token: nil)
        expect(status).to eq(200)
        type = { ".webmanifest" => "application/manifest+json", ".js" => "application/javascript; charset=utf-8",
                 ".png" => "image/png" }.fetch(File.extname(path))
        expect(headers["Content-Type"]).to eq(type)
      end
    end

    it "keeps the page, the other assets and a near miss behind the token" do
      ["/", "/app.js", "/notifications.js", "/icons/favicon.svg", "/sw.js/x", "/icons/chi-181.png", "/assets/sw.js", "/SW.JS"].each do |path|
        expect(call(path, token: nil).first).to eq(401), path
      end
      expect(call("/sw.js", method: "POST", token: nil).first).to eq(401)
    end

    it "still refuses another Host" do
      env = Rack::MockRequest.env_for("/sw.js")
      env["HTTP_HOST"] = "evil.example"
      env["REMOTE_ADDR"] = "127.0.0.1"
      expect(app.call(env).first).to eq(403)
    end
  end
end
