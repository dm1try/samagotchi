# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/anthropic_messages"
require_relative "../support/fake_provider_server"

# Claude 5.x preserved thinking: a replayed thinking block is bound to the
# prefix it was minted after (the system prompt, the tools, the earlier
# messages). When that prefix changed, Messages answers a signature 400;
# the adapter asks again once with drop_block (the binding beta), or strips
# the named block and every thinking block after it, and hands the dropped
# blocks' identities to the loop (ChatResponse#thinking_drop). Recorded
# fixtures from the live Haiku 5.5 probe (README: "Recorded: Claude API").
RSpec.describe Samagotchi::LLM::AnthropicMessages, "binding recovery" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:options) { {} }
  let(:adapter) do
    described_class.new(base_url: server.root_url, host_name: "claude", env: {}, sleeper: ->(_seconds) {},
                        retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 0, base_delay: 0.1, max_delay: 1.0),
                        **options)
  end
  let(:beta) { "thinking-binding-controls-2026-08-01" }
  let(:drop_block) { { "prefix_mismatch_behavior" => "drop_block" } }
  # In the body: messages 1, 3 and 9 hold thinking (sig1, sig2, sig5), as
  # in the recorded request; 5 and 7 are turns without thinking.
  let(:history) do
    [{ role: "system", content: "sys" }, { role: "user", content: "go" },
     *turn("t1", "sig1"), *turn("t2", "sig2"), *turn("t3"), *turn("t4"), *turn("t5", "sig5")]
  end

  after { server.stop }

  def fixture(name) = FakeProviderServer.fixture(name, api: "anthropic")

  def signature_400(name = "claude_error_400_signature_system_changed.json")
    server.enqueue("/v1/messages", status: 400, json: fixture(name))
  end

  def refuse(message)
    server.enqueue("/v1/messages", status: 400, json: { type: "error", error: { type: "invalid_request_error", message: message } })
  end

  def stream(name = "claude_drop_block_input_transformations.sse")
    server.enqueue("/v1/messages", sse: fixture(name))
  end

  def requests = server.requests.select { |r| r.path == "/v1/messages" }

  def bodies = requests.map(&:json)

  def thinking_block(sig) = { "type" => "thinking", "thinking" => "thought #{sig}", "signature" => sig }

  # A model turn's wire message: its saved blocks (+thinking+ first when
  # given), one paired call.
  def turn(id, thinking = nil)
    blocks = [*([thinking_block(thinking)] if thinking), { "type" => "tool_use", "id" => id, "name" => "execute", "input" => {} }]
    [{ role: "assistant", content: nil, anthropic_content: blocks,
       tool_calls: [{ id: id, type: "function", function: { name: "execute", arguments: "{}" } }] },
     { role: "tool", content: "ok #{id}", tool_call_id: id }]
  end

  def chat(level = :high, messages: history, deltas: nil)
    adapter.chat(messages: messages, model: "claude-haiku-5-5", tools: [], options: { max_tokens: 1000, **adapter.thinking_fields(level) },
                 on_delta: deltas && ->(**delta) { deltas << delta })
  end

  def thinking_left(body)
    body["messages"].flat_map { |m| Array(m["content"]) }.select { |b| b["type"] == "thinking" }.map { |b| b["signature"] }
  end

  it "asks again once with the beta and drop_block, and hands on the prefix-dropped blocks the answer names" do
    signature_400
    stream
    allow(Samagotchi::Log).to receive(:info).and_call_original

    response = chat

    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, beta])
    expect(bodies.map { |body| body["thinking"] }).to eq([
      { "type" => "adaptive", "display" => "summarized" },
      { "type" => "adaptive", "display" => "summarized", "block_binding" => drop_block }
    ])
    expect(bodies.last.except("thinking")).to eq(bodies.first.except("thinking"))
    expect(response.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig1 sig2 sig5], how: :drop_block))
    expect(response.tool_calls.size).to eq(3)
    expect(response.provider_content.first).to include("type" => "thinking")
    expect(Samagotchi::Log).to have_received(:info).with(
      :http, "thinking_recovered", host: "claude", model: "claude-haiku-5-5", how: "drop_block", dropped: 3, kept: 0,
                                   why: "The `system` prompt differs from the one this block was created with."
    )
    # ADAPTIVE_REFUSED_RE matches the 400's text ("…adaptive…" in no such
    # path here, "thinking" everywhere): never the budget form.
    expect(adapter.budget_form?("claude-haiku-5-5")).to be(false)
  end

  it "sends the default level (no thinking field) adaptive with drop_block on the retry" do
    signature_400
    stream

    chat(:default)

    expect(bodies.map { |body| body["thinking"] }).to eq([nil, { "type" => "adaptive", "block_binding" => drop_block }])
  end

  it "keeps a model_binding_mismatch drop out of thinking_drop (a /model downgrade: those blocks stay)" do
    signature_400
    stream("drop_block_model_binding_stream.hand-written.sse")

    expect(chat.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig1], how: :drop_block))
  end

  it "strips under thinking disabled: the named block and every thinking block after it, no beta" do
    signature_400
    stream("text_stream.hand-written.sse")

    response = chat(:off)

    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, nil])
    expect(bodies.map { |body| thinking_left(body) }).to eq([%w[sig1 sig2 sig5], []])
    expect(bodies.last["thinking"]).to eq("type" => "disabled")
    expect(response.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig1 sig2 sig5], how: :strip))
  end

  it "goes straight to strip for a tampered signature (no 'bound to a different conversation'), from the block it names" do
    signature_400("error_400_signature_invalid.hand-written.json")
    stream("text_stream.hand-written.sse")

    response = chat

    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, nil])
    expect(bodies.last["thinking"]).to eq("type" => "adaptive", "display" => "summarized")
    expect(thinking_left(bodies.last)).to eq(%w[sig1])
    expect(response.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig2 sig5], how: :strip))
  end

  it "strips from the first replayed thinking block when the 400 names no block it can find" do
    refuse("Invalid `signature` in `thinking` block.")
    stream("text_stream.hand-written.sse")

    expect(chat.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig1 sig2 sig5], how: :strip))
    expect(thinking_left(bodies.last)).to eq([])
  end

  it "strips when the host refuses the binding controls, remembers it, and strips directly next time" do
    signature_400
    server.enqueue("/v1/messages", status: 400, json: fixture("error_400_block_binding_extra.hand-written.json"))
    stream("text_stream.hand-written.sse")
    signature_400
    stream("text_stream.hand-written.sse")
    allow(Samagotchi::Log).to receive(:info).and_call_original

    first = chat
    second = chat

    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, beta, nil, nil, nil])
    expect(bodies.map { |body| thinking_left(body).size }).to eq([3, 3, 0, 3, 0])
    expect([first, second].map(&:thinking_drop))
      .to all(eq(Samagotchi::LLM::ThinkingDrop.new(identities: %w[sig1 sig2 sig5], how: :strip)))
    expect(Samagotchi::Log).to have_received(:info).with(:http, "binding_controls_refused", any_args).once
  end

  it "strips after a second signature 400 on the drop_block retry, and raises on a third" do
    signature_400
    signature_400
    stream("text_stream.hand-written.sse")
    3.times { signature_400 }

    expect(chat.thinking_drop.how).to eq(:strip)
    expect(bodies.map { |body| thinking_left(body).size }).to eq([3, 3, 0])
    expect(bodies[2]["thinking"]).not_to have_key("block_binding")

    expect { chat }.to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.thinking_signature?).to be(true) }
    expect(bodies.size).to eq(6)
  end

  it "keeps block_binding and the beta when a refusal fix rebuilds the drop_block retry (display refused)" do
    signature_400
    refuse("thinking.adaptive.display: Extra inputs are not permitted")
    stream

    expect(chat.thinking_drop.how).to eq(:drop_block)
    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, beta, beta])
    expect(bodies.last["thinking"]).to eq("type" => "adaptive", "block_binding" => drop_block)
  end

  it "keeps the strip when a refusal fix rebuilds the stripped retry" do
    signature_400("error_400_signature_invalid.hand-written.json")
    refuse("cache_control: Extra inputs are not permitted")
    stream("text_stream.hand-written.sse")

    expect(chat.thinking_drop.how).to eq(:strip)
    expect(bodies.map { |body| thinking_left(body) }).to eq([%w[sig1 sig2 sig5], %w[sig1], %w[sig1]])
    expect(bodies.last.to_s).not_to include("cache_control")
  end

  it "raises a signature 400 for a body that replays no thinking block (nothing to drop)" do
    signature_400

    expect { chat(messages: [{ role: "user", content: "hi" }]) }.to raise_error(Samagotchi::LLM::BadRequest)
    expect(bodies.size).to eq(1)
  end

  it "leaves any other 400 alone" do
    server.enqueue("/v1/messages", status: 400, json: fixture("error_400_prompt_too_long.hand-written.json"))

    expect { chat }.to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.context_overflow?).to be(true) }
    expect(bodies.size).to eq(1)
  end

  it "sets no thinking_drop on an answer that needed no recovery" do
    stream("text_stream.hand-written.sse")

    expect(chat.thinking_drop).to be_nil
    expect(requests.first.header("anthropic-beta")).to be_nil
  end

  it "doesn't ask again after the stream showed something (a mid-stream error event: deltas never repeat)" do
    sse = fixture("stream_error.hand-written.sse").sub(
      /"error":\{.*\}\}/,
      '"error":{"type":"invalid_request_error","message":"messages.1.content.0: Invalid `signature` in `thinking` block. ' \
      'The block is bound to a different conversation."}}'
    )
    server.enqueue("/v1/messages", sse: sse)

    expect { chat(deltas: []) }.to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.thinking_signature?).to be(true) }
    expect(bodies.size).to eq(1)
  end

  context "with the fireworks dialect (same rules; it never sees these 400s)" do
    let(:options) { { dialect: "fireworks" } }

    it "asks again with drop_block and no display" do
      signature_400
      stream

      expect(chat.thinking_drop.how).to eq(:drop_block)
      expect(bodies.last["thinking"]).to eq("type" => "adaptive", "block_binding" => drop_block)
      expect(requests.last.header("anthropic-beta")).to eq(beta)
    end
  end
end
