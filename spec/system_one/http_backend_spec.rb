# frozen_string_literal: true

require "samagotchi/host_registry"
require "samagotchi/system_one"
require_relative "../support/fake_provider_server"

# The judgment POST against a real local server: the URL, the body, the key,
# and every way it can go wrong (422, no JSON, too slow, the wrong kind of
# host) ending in no judgment.
RSpec.describe Samagotchi::SystemOne::HttpBackend do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:questions) { { "git-push" => Samagotchi::SystemOne::Question.new(id: "git-push", type: :noul, instructions: "allow this push?") } }
  let(:judged) { { "model" => "judge", "answers" => { "git-push" => { "type" => "noul", "noul" => 0.97 } }, "usage" => { "input_tokens" => 12 } } }

  def registry(extra = {})
    Samagotchi::HostRegistry.new(hosts_config: {
      "one" => { url: server.base_url, api: :openai, models: ["judge-first"], remote: true, **extra },
      "plain" => { host: "127.0.0.1", port: server.port, api: :openai, models: ["plain-judge"] },
      "raw" => { host: "127.0.0.1", port: server.port, api: :llamacpp }
    })
  end

  def backend(host: "one", model: "judge", timeout_ms: 2000, env: {})
    described_class.new(host_registry: registry, host: host, model: model, timeout_ms: timeout_ms, env: env)
  end

  def client(backend) = Samagotchi::SystemOne::Client.new(backend: backend, mode: "audit", host: "one")

  after { server.stop }

  it "posts the contract to the host's /v1/systemone and reads the answers" do
    server.enqueue("/v1/systemone", json: judged)
    answers = backend.ask(state: "git push origin main", questions: questions)
    expect(answers["git-push"]).to have_attributes(id: "git-push", type: :noul, noul: 0.97)

    request = server.requests.last
    expect(request.method).to eq("POST")
    expect(request.path).to eq("/v1/systemone")
    expect(request.json).to eq({ "model" => "judge", "state" => "git push origin main",
                                 "questions" => { "git-push" => { "type" => "noul", "instructions" => "allow this push?" } } })
    expect(request.header("content-type")).to eq("application/json")
  end

  it "sends exactly one /v1, whether the host is configured by url or by host and port" do
    2.times { server.enqueue("/v1/systemone", json: judged) }
    described_class.new(host_registry: registry, host: "one", model: "judge", timeout_ms: 2000, env: {}).ask(state: "x", questions: questions)
    described_class.new(host_registry: registry, host: "plain", timeout_ms: 2000, env: {}).ask(state: "x", questions: questions)

    paths = server.requests.map(&:path)
    expect(paths).to eq(["/v1/systemone", "/v1/systemone"])
    expect(paths.map { |path| path.scan("/v1").size }).to eq([1, 1])
  end

  it "uses the host's first model when the settings name none, and refuses one that names none" do
    server.enqueue("/v1/systemone", json: judged)
    expect(backend(model: nil).ask(state: "x", questions: questions)["git-push"].noul).to eq(0.97)
    expect(server.requests.last.json["model"]).to eq("judge-first")

    bare = described_class.new(host_registry: Samagotchi::HostRegistry.new(hosts_config: { "two" => { url: server.base_url, api: :openai } }), host: "two")
    expect { bare.ask(state: "x", questions: questions) }.to raise_error(Samagotchi::SystemOne::UnsupportedHost, /names no model/)
  end

  it "sends the host's key as a bearer token when it has one" do
    server.enqueue("/v1/systemone", json: judged)
    described_class.new(host_registry: registry(api_key_env: "SYSTEM_ONE_TEST_KEY"), host: "one", model: "judge",
                        timeout_ms: 2000, env: { "SYSTEM_ONE_TEST_KEY" => "judge-key" }).ask(state: "x", questions: questions)
    expect(server.requests.last.header("authorization")).to eq("Bearer judge-key")
  end

  it "is no judgment when the host is not an openai one" do
    expect { backend(host: "raw").ask(state: "x", questions: questions) }
      .to raise_error(Samagotchi::SystemOne::UnsupportedHost, /api: llamacpp/)
    allow(Samagotchi::Log).to receive(:warn)
    expect(client(backend(host: "raw")).ask(state: "x", questions: questions)).to be_nil
  end

  it "is no judgment for a host that isn't in hosts:" do
    expect { backend(host: "who").ask(state: "x", questions: questions) }
      .to raise_error(Samagotchi::SystemOne::UnsupportedHost, /is not in hosts:/)
  end

  it "is no judgment on a 422, with the server's detail in the log" do
    server.enqueue("/v1/systemone", status: 422, json: { "detail" => [{ "loc" => %w[body model], "msg" => "model q is not served by this endpoint" }] })
    expect(Samagotchi::Log).to receive(:warn).with(:guardrails, "system_one_failed",
                                                   hash_including(echo: /422 model q is not served by this endpoint/))
    expect(client(backend).ask(state: "x", questions: questions)).to be_nil
  end

  it "is no judgment when the body isn't JSON, or has no answers" do
    server.enqueue("/v1/systemone", body: "<html>nope</html>")
    server.enqueue("/v1/systemone", json: { "model" => "judge" })
    allow(Samagotchi::Log).to receive(:warn)

    expect(client(backend).ask(state: "x", questions: questions)).to be_nil
    expect(client(backend).ask(state: "x", questions: questions)).to be_nil
  end

  it "is no judgment when the server is slower than timeout_ms" do
    server.enqueue("/v1/systemone", sse: ["{\"answers\": {\"git-push\": {\"type\": \"noul\", \"noul\": 0.9}}", "}"], delay: 0.4)
    allow(Samagotchi::Log).to receive(:warn)
    expect(client(backend(timeout_ms: 200)).ask(state: "x", questions: questions)).to be_nil
    expect(server.requests.size).to eq(1) # one attempt, no retry chain
  end
end
