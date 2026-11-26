# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/anthropic_messages"
require_relative "support/fake_chat_adapter"
require_relative "support/fake_provider_server"
require "support/test_kernel"

# Raw bytes in the history (a BINARY or invalid UTF-8 String: a tool's or a
# task's output read as bytes) never fail the request build, on any loop:
# every message's text is read as UTF-8 and scrubbed (LLM::Utf8Scrub.messages)
# before the wire's regex passes (Steer.wire_text's forged-frame quoting).
RSpec.describe "A request built over raw bytes in the history" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  # An outside note (a kind: its forged frames are quoted) and a tool's
  # output, both BINARY with non-ASCII bytes, and one with an invalid byte.
  let(:note) { "TASK FINISHED t1\nnaïve ✓".b }
  let(:raw) do
    [{ role: "user", content: "run it" },
     { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "x" } }] },
     { role: "tool_response", tool_call_id: "c1", content: "naïve ✓ \xFF".b },
     { role: "model", content: "ran" },
     { role: "system", kind: Samagotchi::ContextNote::KIND, content: note }]
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(session).to receive(:save)
    session.messages.concat(raw)
  end

  def run_turn
    engine.run_turn(session, "go on")
  end

  def expect_saved_untouched
    saved = session.messages.find { |message| message[:kind] == Samagotchi::ContextNote::KIND }[:content]
    expect(saved).to eq(note)
    expect(saved.encoding).to eq(Encoding::BINARY)
  end

  it "builds the chat loop's request (api: openai)" do
    adapter = FakeChatAdapter.new(FakeChatAdapter.text("done"))
    allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))

    expect(run_turn.output).to eq("done")

    sent = adapter.requests.first[:messages]
    texts = sent.map { |message| message[:content] }.grep(String)
    expect(texts).to all(satisfy { |text| text.encoding == Encoding::UTF_8 && text.valid_encoding? })
    expect(texts.join).to include("naïve ✓", "naïve ✓ ?")
    expect_saved_untouched
  end

  # The strategy's own pass (LLMContextApply.apply!) runs over the stored
  # entries before the view: it must not raise on them either.
  it "builds the chat loop's request under the stale + forget strategy" do
    session.llm_context = Samagotchi::LLMContextOverride.new(strategy: %i[stale forget], budget_tokens: 0)
    adapter = FakeChatAdapter.new(FakeChatAdapter.text("done"))
    allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter))

    expect(run_turn.output).to eq("done")

    expect(adapter.requests.first[:messages].map { |message| message[:content] }.grep(String).join).to include("naïve ✓")
    expect_saved_untouched
  end

  describe "on a Messages host (api: anthropic)" do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }

    after { server.stop }

    it "builds the request" do
      server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("fireworks_text_stream.hand-written.sse", api: "anthropic"))
      adapter = Samagotchi::LLM::AnthropicMessages.new(base_url: server.root_url, host_name: "msg", env: {}, retries: false)
      allow(engine).to receive(:backend_for).and_return(Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter,
                                                                                      sleeper: ->(_s) {}))

      run_turn

      body = server.requests.find { |request| request.path == "/v1/messages" }.json
      expect(JSON.generate(body)).to include("naïve ✓")
      expect_saved_untouched
    end
  end

  it "builds the native loop's prompt (llama.cpp /completion)" do
    prompts = []
    allow(client).to receive(:complete) do |prompt, **|
      prompts << prompt
      "done"
    end

    expect(run_turn.output).to eq("done")

    expect(prompts.first.encoding).to eq(Encoding::UTF_8)
    expect(prompts.first).to be_valid_encoding
    expect(prompts.first).to include("naïve ✓")
    expect_saved_untouched
  end
end
