# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/plugin/context"
require "samagotchi/broadcast/triage"
require_relative "support/fake_provider_server"

# Side requests (a recap, ctx.ask_model, a broadcast's triage) on an
# api: anthropic host, end to end against the fake server: the side
# client talks the host's Messages API with its dialect.
RSpec.describe "Side requests on a Messages host" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "fw" => { url: server.root_url, api: :anthropic, dialect: "fireworks", api_key_env: "FW_SIDE_KEY", remote: true }
    })
  end
  let(:bodies) { server.requests.select { |r| r.path == "/v1/messages" }.map(&:json) }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    stub_const("ENV", ENV.to_h.merge("FW_SIDE_KEY" => "fw-side"))
  end

  after { server.stop }

  def message(text) = { type: "message", role: "assistant", model: "kimi", stop_reason: "end_turn", content: [{ type: "text", text: text }] }

  def refuse_off
    server.enqueue("/v1/messages", status: 400,
                                   json: { type: "error", error: { type: "invalid_request_error",
                                                                   message: "thinking cannot be disabled for this model" } })
  end

  it "points recap.host_ref at the host's Messages API, with its dialect", :recap do
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m", recap: { host_ref: "fw", model: "fw:kimi" })

    expect(engine.recap.target).to have_attributes(base_url: server.root_url, api: :anthropic, dialect: "fireworks",
                                                   api_key_env: "FW_SIDE_KEY", model: "kimi")
  end

  it "answers a plugin's ctx.ask_model on the session's Messages host: Bearer, low effort after off is refused" do
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "fw:kimi")
    ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
    refuse_off
    server.enqueue("/v1/messages", json: message("We renamed foo."))

    expect(ctx.ask_model(messages: [{ role: "user", content: "rename foo" }], prompt: "what did we rename?"))
      .to eq("We renamed foo.")
    expect(bodies.map { |b| [b["thinking"], b["output_config"]] })
      .to eq([[{ "type" => "disabled" }, nil], [{ "type" => "adaptive" }, { "effort" => "low" }]])
    expect(bodies.last["max_tokens"]).to be >= Samagotchi::IdleClient::THINKING_MAX_TOKENS
    expect(server.requests.last.header("authorization")).to eq("Bearer fw-side")
  end

  it "keeps the side client between ctx.ask_model calls (the refusal holds) and sends the session's id" do
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "fw:kimi")
    engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: "fw:kimi", working_directory: Dir.pwd)
    ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
    refuse_off
    2.times { server.enqueue("/v1/messages", json: message("ok.")) }

    2.times { ctx.ask_model(messages: [], prompt: "q?") }

    expect(bodies.map { |b| b.dig("thinking", "type") }).to eq(%w[disabled adaptive adaptive])
    expect(server.requests.select { |r| r.path == "/v1/messages" }.map { |r| r.header("x-session-affinity") })
      .to eq([engine.session.id] * 3)
  end

  it "judges a broadcast's card on a Messages host by its plain yes or no (no logprobs there)" do
    target = Samagotchi::IdleTarget.of_model(registry, "fw:kimi")
    judge = Samagotchi::Broadcast::Triage::LLM.new(target: target, timeout: 5)
    server.enqueue("/v1/messages", json: message("yes"))

    verdict = judge.judge("bump the gem", "project chi, branch main")

    expect(verdict).to have_attributes(relevant: true, by: "model")
    expect(bodies.last.keys).not_to include("logprobs", "top_logprobs")
    expect(server.requests.last.header("x-session-affinity")).to be_nil
  ensure
    Samagotchi::Broadcast::Triage::LLM.reset_logprobs!
  end
end
