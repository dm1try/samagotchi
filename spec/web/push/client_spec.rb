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
  let(:answer) { [201, ""] }
  let(:server) do
    WEBrick::HTTPServer.new(Port: 0, BindAddress: "127.0.0.1", AccessLog: [], Logger: WEBrick::Log.new(File::NULL)).tap do |s|
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

  before { @thread = Thread.new { server.start } }

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

  it "is failed, with the error's class and no message, when the service can't be reached" do
    refused = ->(_uri, _request) { raise Errno::ECONNREFUSED, "https://web.push.apple.com/QGdevice1" }
    result = described_class.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: refused).deliver(sub, {}, ttl: 1, urgency: "high")
    expect(result).to have_attributes(status: :failed, code: nil, error: "Errno::ECONNREFUSED")

    slow = ->(_uri, _request) { raise Net::ReadTimeout }
    expect(described_class.new(key: store.vapid_key, contact: "mailto:a@b.c", transport: slow).deliver(sub, {}, ttl: 1, urgency: "high").error)
      .to eq("timeout")
  end
end
