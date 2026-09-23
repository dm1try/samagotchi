# frozen_string_literal: true

require "spec_helper"
require "net/http"
require_relative "support/fake_provider_server"

RSpec.describe FakeProviderServer do
  around { |example| described_class.without_webmock { example.run } }

  let(:server) { described_class.start }

  after { server.stop }

  def post(path, body, &block)
    uri = URI("#{server.root_url}#{path}")
    Net::HTTP.start(uri.host, uri.port, read_timeout: 5) do |http|
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Authorization"] = "Bearer sk-test"
      request.body = JSON.generate(body)
      http.request(request, &block)
    end
  end

  it "replays a recorded stream byte for byte" do
    fixture = described_class.fixture("text_stream.sse")
    server.enqueue("/v1/chat/completions", sse: fixture)

    response = post("/v1/chat/completions", { stream: true })

    expect(response.code).to eq("200")
    expect(response["Content-Type"]).to eq("text/event-stream")
    expect(response.body).to eq(fixture)
  end

  it "records each request's path, headers and JSON body" do
    server.enqueue("/v1/chat/completions", json: { ok: true })

    post("/v1/chat/completions", { model: "m", messages: [{ role: "user", content: "hi" }] })

    request = server.requests.last
    expect(request.path).to eq("/v1/chat/completions")
    expect(request.header("authorization")).to eq("Bearer sk-test")
    expect(request.json["messages"]).to eq([{ "role" => "user", "content" => "hi" }])
  end

  it "serves queued responses in order, then the default, then 404" do
    server.enqueue("/v1/models", status: 500, json: { error: { message: "boom" } })
    server.default("/v1/models", json: described_class.fixture("models.json"))

    uri = URI("#{server.base_url}/models")
    codes = Array.new(2) { Net::HTTP.get_response(uri).code }
    missing = Net::HTTP.get_response(URI("#{server.base_url}/nope")).code

    expect(codes).to eq(%w[500 200])
    expect(missing).to eq("404")
  end

  it "sends headers such as Retry-After" do
    server.enqueue("/v1/chat/completions", status: 429, json: described_class.fixture("error_429.hand-written.json"),
                                           headers: { "Retry-After" => "7" })

    response = post("/v1/chat/completions", {})

    expect(response.code).to eq("429")
    expect(response["Retry-After"]).to eq("7")
  end

  # The point of a real server: the client sees each event as it is sent,
  # not the whole body at the end.
  it "streams events one at a time, holding the stream open until released" do
    events = described_class.sse_events(described_class.fixture("text_stream.sse"))
    server.enqueue("/v1/chat/completions", sse: events.first(2), hold: true)
    received = Queue.new

    reader = Thread.new do
      post("/v1/chat/completions", { stream: true }) do |response|
        response.read_body { |chunk| received << chunk }
      end
    end

    first = received.pop(timeout: 3)
    expect(first).to eq(events.first)
    sleep 0.2
    expect(reader).to be_alive
    server.release
    expect(reader.join(3)).to be_truthy
  end
end
