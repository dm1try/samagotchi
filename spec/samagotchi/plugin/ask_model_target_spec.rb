# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/plugin/context"
require "samagotchi/testing"
require_relative "../../support/fake_provider_server"

# ctx.ask_model(model:): a configured model instead of the session's, on a
# real Engine and a fake server. IdleTarget.of_model never raises, so the
# Engine validates the ref first.
RSpec.describe "ctx.ask_model(model:)" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "fw" => { url: server.root_url, api: :anthropic, dialect: "fireworks", api_key_env: "FW_SIDE_KEY", remote: true,
                models: Samagotchi::HostModel.parse_map(["kimi-declared"], "spec") }
    })
  end
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "box:m") }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host)) }
  let(:messages_requests) { server.requests.select { |r| r.path == "/v1/messages" } }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "kimi" => "fw:kimi-real" })
    stub_const("ENV", ENV.to_h.merge("FW_SIDE_KEY" => "fw-side"))
  end

  after { server.stop }

  def message(text) = { type: "message", role: "assistant", model: "kimi", stop_reason: "end_turn", content: [{ type: "text", text: text }] }

  def ask(model) = ctx.ask_model(messages: [], prompt: "q?", model: model)

  it "asks a host:id ref's host and model, not the session's (the host's key, the id sent)" do
    server.enqueue("/v1/messages", json: message("from fw"))

    expect(ask("fw:kimi-real")).to eq("from fw")
    expect(messages_requests.last.json["model"]).to eq("kimi-real")
    expect(messages_requests.last.header("authorization")).to eq("Bearer fw-side")
  end

  it "takes an alias, and a bare id a host declares" do
    2.times { |i| server.enqueue("/v1/messages", json: message("answer #{i}")) }

    expect(ask("kimi")).to eq("answer 0")
    expect(ask("kimi-declared")).to eq("answer 1")
    expect(messages_requests.map { |r| r.json["model"] }).to eq(%w[kimi-real kimi-declared])
  end

  it "takes an alias whose target is a bare id no host lists (as --model does)" do
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return({ "fast" => "gpt-mini" })

    expect { engine.send(:configured_side_target, "fast") }.not_to raise_error
    expect(engine.send(:configured_side_target, "fast")).to have_attributes(model: "gpt-mini", label: "fast")
    expect { engine.send(:configured_side_target, "gpt-mini") }.to raise_error(ArgumentError, /unknown model/)
  end

  it "raises ArgumentError, asking nothing, for an unknown host, an unlisted bare id or a blank ref" do
    expect { ask("nohost:kimi") }.to raise_error(ArgumentError, /unknown model "nohost:kimi"/)
    expect { ask("never-heard-of-it") }.to raise_error(ArgumentError, /unknown model/)
    expect { ask(" ") }.to raise_error(ArgumentError, /model:/)
    expect { ask(:sym) }.to raise_error(ArgumentError, /model:/)
    expect(server.requests).to be_empty
  end

  it "asks the session's model again when model: is nil (the existing path)" do
    plain = Samagotchi::Engine.new(host_registry: registry, model_name: "fw:kimi-real")
    context = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: plain.send(:plugin_host))
    server.enqueue("/v1/messages", json: message("session's"))

    expect(context.ask_model(messages: [], prompt: "q?")).to eq("session's")
    expect(messages_requests.last.json["model"]).to eq("kimi-real")
  end

  # The side line counts it under the asking bundle's name, priced from the
  # target's host (by the id asked for), not the session's.
  it "counts the request in the session's side block under the bundle's name, priced from the target's host" do
    priced = Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "fw" => { url: server.root_url, api: :anthropic, dialect: "fireworks", api_key_env: "FW_SIDE_KEY", remote: true,
                models: Samagotchi::HostModel.parse_map({ "kimi-real" => { "price" => { "input" => 2.0, "output" => 10.0 } } }, "spec") }
    })
    session_engine = Samagotchi::Engine.new(host_registry: priced, model_name: "box:m")
    context = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: session_engine.send(:plugin_host))
    server.enqueue("/v1/messages", json: message("priced").merge(usage: { input_tokens: 1000, output_tokens: 100 }))

    context.ask_model(messages: [], prompt: "q?", model: "fw:kimi-real")

    side = session_engine.metrics.snapshot[:side]
    expect(side).to include(requests: 1, prompt_sum: 1000, completion_sum: 100, cost_sum: nil)
    expect(side[:by_kind].keys).to eq(["b"])
    expect(side[:cost_estimate_sum]).to be_within(1e-12).of(((1000 * 2.0) + (100 * 10.0)) / 1e6)
  end

  it "keeps one side client while the target stays and builds another for another target" do
    2.times { server.enqueue("/v1/messages", json: message("ok")) }
    ask("fw:kimi-real")
    first = engine.instance_variable_get(:@side_client)
    ask("fw:kimi-real")
    expect(engine.instance_variable_get(:@side_client)).to equal(first)

    server.enqueue("/v1/messages", json: message("ok"))
    ask("fw:kimi-declared")
    expect(engine.instance_variable_get(:@side_client)).not_to equal(first)
  end

  describe "in the test kit" do
    it "records the model: a request named (nil: the session's)" do
      recorder = Samagotchi::Testing::Recorder.new
      host = Samagotchi::Testing::Host.build(recorder)
      kit_ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: host)
      recorder.model_answers.concat(%w[a b])

      kit_ctx.ask_model(messages: [], prompt: "q")
      kit_ctx.ask_model(messages: [], prompt: "q", model: " fw:kimi ")

      expect(recorder.model_requests.map(&:model)).to eq([nil, "fw:kimi"])
    end
  end
end
