# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "webrick"
require "samagotchi/web/push/client"
require "samagotchi/web/push/store"
require_relative "../../support/web_push_receiver"

# A fake push service (WEBrick on a random port, plain http through the
# injected transport) that decrypts what the Client sends with the device's
# own key, as the device would, and answers as the test case says.
RSpec.describe Samagotchi::Web::Push::Client do
  let(:root) { Dir.mktmpdir("push-client-spec") }
  let(:store) { Samagotchi::Web::Push::Store.new(File.join(root, "web-push"), clock: -> { now }) }
  let(:now) { Time.at(1_800_000_000) }
  let(:receiver) { WebPushReceiver.new }
  let(:sub) { store.add(receiver.subscription("https://web.push.apple.com/QGdevice1"), origin: "https://s.example", label: "iPhone") }
  let(:requests) { Queue.new }
  let(:started) { Queue.new }
  let(:answer) { [201, ""] }
  let(:server) do
    WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", AccessLog: [], Logger: WEBrick::Log.new(File::NULL),
                            StartCallback: -> { started << true }).tap do |s|
      s.mount_proc("/") do |req, res|
        requests << { path: req.path, headers: req.header.transform_values(&:first), body: req.body }
        res.status, res.body = answer
      end
    end
  end
  # The endpoint's path, on the fake service: what TLS would reach on 443.
  let(:transport) do
    lambda do |uri, request|
      Net::HTTP.start("127.0.0.1", server.config[:Port], open_timeout: 2, read_timeout: 5) do |http|
        request["Host"] = uri.host
        http.request(request)
      end
    end
  end
  let(:client) { described_class.new(key: store.vapid_key, contact: "https://s.example", transport: transport, clock: -> { now }) }

  around do |example|
    WebMock.disable!
    example.run
  ensure
    WebMock.enable!
  end

  # Running before an example goes on: a shutdown that lands before start begins is lost and start never returns
  # (an example that never reaches the service shuts it down at once).
  before do
    @thread = Thread.new { server.start }
    pop!(started, "the fake push service to start")
  end

  after do
    server.shutdown
    join!(@thread, "the fake push service")
    FileUtils.rm_rf(root)
  end

  it "sends the payload encrypted for the device, with chi's VAPID header, TTL and urgency" do
    result = client.deliver(sub, { v: 1, kind: "show", title: "fix the build" }, ttl: 43_200, urgency: "high")

    expect(result).to have_attributes(status: :ok, code: 201, error: nil)
    expect(result.ms).to be >= 0
    seen = pop!(requests, "the push")
    expect(seen[:path]).to eq("/QGdevice1")
    expect(seen[:headers]).to include("content-encoding" => "aes128gcm", "ttl" => "43200", "urgency" => "high",
                                      "content-type" => "application/octet-stream")
    expect(JSON.parse(receiver.decrypt(seen[:body]))).to eq("v" => 1, "kind" => "show", "title" => "fix the build")
    claims = WebPushReceiver.vapid_claims(seen[:headers]["authorization"])
    expect(claims).to eq("aud" => "https://web.push.apple.com", "exp" => now.to_i + (12 * 3600), "sub" => "https://s.example")
    expect(seen[:headers]["authorization"]).to end_with("k=#{Samagotchi::Web::Push::Crypto.public_key_b64(store.vapid_key)}")
  end

  {
    [410, ""] => [:gone, 410, nil],
    [404, ""] => [:gone, 404, nil],
    [403, '{"reason":"BadJwtToken"}'] => [:bad_jwt, 403, nil],
    [403, '{"reason":"Forbidden"}'] => [:failed, 403, "403"],
    [500, "oops"] => [:failed, 500, "500"]
  }.each do |(code, body), (status, want_code, error)|
    context "when the service answers #{code} #{body}" do
      let(:answer) { [code, body] }

      it "is #{status}" do
        expect(client.deliver(sub, { v: 1 }, ttl: 600, urgency: "normal"))
          .to have_attributes(status: status, code: want_code, error: error)
        pop!(requests, "the push")
      end
    end
  end

  it "says when a retry may go after a 429 or 5xx: its Retry-After seconds up to 60, else 10; never for others" do
    answering = lambda do |code, retry_after = nil|
      response = Struct.new(:code, :body, :retry_after) { def [](name) = name == "Retry-After" ? retry_after : nil }
      transport = ->(_uri, _request) { response.new(code.to_s, "", retry_after) }
      described_class.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: transport)
                     .deliver(sub, {}, ttl: 1, urgency: "high").retry_after
    end
    expect(answering.call(429, "2")).to eq(2)
    expect(answering.call(503, "120")).to eq(60)
    expect(answering.call(500)).to eq(10)
    expect(answering.call(502, "Wed, 21 Oct 2026 07:28:00 GMT")).to eq(10)
    expect(answering.call(429, "-3")).to eq(10)
    expect(answering.call(201, "5")).to be_nil
    expect(answering.call(410, "5")).to be_nil
    expect(answering.call(403, "5")).to be_nil
  end

  it "is failed, with the error's class and no message, when the service can't be reached" do
    refused = ->(_uri, _request) { raise Errno::ECONNREFUSED, "https://web.push.apple.com/QGdevice1" }
    result = described_class.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: refused).deliver(sub, {}, ttl: 1, urgency: "high")
    expect(result).to have_attributes(status: :failed, code: nil, error: "Errno::ECONNREFUSED", retry_after: nil)

    slow = ->(_uri, _request) { raise Net::ReadTimeout }
    expect(described_class.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: slow).deliver(sub, {}, ttl: 1, urgency: "high").error)
      .to eq("timeout")
  end

  it "is failed, with the error's class, for a device whose key on disk is off the curve, and posts nothing" do
    WebPushReceiver.spoil(store, sub.id)
    result = client.deliver(store.find(sub.id), { kind: "show" }, ttl: 1, urgency: "high")
    expect(result).to have_attributes(status: :failed, code: nil, error: "ArgumentError", retry_after: nil)
    expect(requests).to be_empty
  end
end
