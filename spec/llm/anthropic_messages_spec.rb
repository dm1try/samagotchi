# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/host_registry"
require_relative "../support/fake_provider_server"

# The Messages adapter against the fake server and the recorded/hand-written
# fixtures in spec/fixtures/providers/anthropic: the exact request body
# ChatLoop's wire messages become, and the ChatResponse a body gives.
RSpec.describe Samagotchi::LLM::AnthropicMessages do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:env) { {} }
  let(:options) { {} }
  let(:adapter) do
    described_class.new(base_url: server.root_url, host_name: "msg", env: env, stream: false, sleeper: ->(_seconds) {},
                        retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 0, base_delay: 0.1, max_delay: 1.0),
                        **options)
  end
  let(:tools) do
    [{ type: "function", function: { name: "execute", description: "Run a command.",
                                     parameters: { type: "object", properties: { command: { type: "string" } } } } }]
  end

  after { server.stop }

  def fixture(name) = FakeProviderServer.fixture(name, api: "anthropic")

  def answer(name = "splash_text_sync.json", status: 200)
    server.enqueue("/v1/messages", status: status, json: fixture(name))
  end

  def sent = server.requests.find { |request| request.path == "/v1/messages" }.json

  def chat(messages, tools: [], model: "m", **)
    adapter.chat(messages: messages, tools: tools, model: model, **)
  end

  describe "the request" do
    it "posts a text turn to {base}/v1/messages: the system on top, max_tokens, no tools" do
      answer

      chat([{ role: "system", content: "sys" }, { role: "user", content: [{ type: "text", text: "hi" }] }],
           options: { max_tokens: 1000 })

      expect(server.requests.last.path).to eq("/v1/messages")
      expect(sent).to eq(
        "model" => "m", "max_tokens" => 1000,
        "system" => [{ "type" => "text", "text" => "sys", "cache_control" => { "type" => "ephemeral" } }],
        "messages" => [{ "role" => "user",
                         "content" => [{ "type" => "text", "text" => "hi", "cache_control" => { "type" => "ephemeral" } }] }],
        "stream" => false
      )
    end

    it "sends a tool turn: tool_use blocks with the input object, every result in one user message, ids mapped" do
      answer
      messages = [
        { role: "system", content: "sys" },
        { role: "user", content: [{ type: "text", text: "weather?" }] },
        { role: "assistant", content: "Checking.", reasoning_content: "hidden",
          tool_calls: [{ id: "call.1", type: "function", function: { name: "get_weather", arguments: '{"city":"Paris"}' } },
                       { id: "call:2", type: "function", function: { name: "get_weather", arguments: '{"city":"Oslo"}' } }] },
        { role: "tool", content: "12C", tool_call_id: "call.1" },
        { role: "tool", content: "11C", tool_call_id: "call:2" }
      ]

      chat(messages, tools: tools, options: { max_tokens: 100 })

      expect(sent["messages"]).to eq([
        { "role" => "user", "content" => [{ "type" => "text", "text" => "weather?" }] },
        { "role" => "assistant", "content" => [
          { "type" => "text", "text" => "Checking." },
          { "type" => "tool_use", "id" => "call_1_e8b7b7b3", "name" => "get_weather", "input" => { "city" => "Paris" } },
          { "type" => "tool_use", "id" => "call_2_33331b62", "name" => "get_weather", "input" => { "city" => "Oslo" } }
        ] },
        { "role" => "user", "content" => [
          { "type" => "tool_result", "tool_use_id" => "call_1_e8b7b7b3", "content" => "12C" },
          { "type" => "tool_result", "tool_use_id" => "call_2_33331b62", "content" => "11C", "cache_control" => { "type" => "ephemeral" } }
        ] }
      ])
      expect(sent["tools"]).to eq([{ "name" => "execute", "description" => "Run a command.",
                                     "input_schema" => { "type" => "object",
                                                         "properties" => { "command" => { "type" => "string" } } } }])
      expect(sent["tool_choice"]).to eq("type" => "auto")
    end

    it "sends a call whose arguments aren't a JSON object with input {}, and drops an empty assistant message" do
      answer
      messages = [
        { role: "user", content: "go" },
        { role: "assistant", content: "",
          tool_calls: [{ id: "a", type: "function", function: { name: "execute", arguments: "{not json" } }] },
        { role: "tool", content: "", tool_call_id: "a" },
        { role: "assistant", content: "  " },
        { role: "user", content: "next" }
      ]

      chat(messages)

      expect(sent["messages"].map { |m| [m["role"], m["content"].map { |b| b.except("cache_control") }] }).to eq([
        ["user", [{ "type" => "text", "text" => "go" }]],
        ["assistant", [{ "type" => "tool_use", "id" => "a", "name" => "execute", "input" => {} }]],
        ["user", [{ "type" => "tool_result", "tool_use_id" => "a" }, { "type" => "text", "text" => "next" }]]
      ])
    end

    it "sends images: a data URL as base64, an http(s) URL as a url source, tool images after the results" do
      answer
      png = "data:image/png;base64,iVBORw0KGgo="
      messages = [
        { role: "user", content: [{ type: "text", text: "look" }, { type: "image_url", image_url: { url: png } },
                                  { type: "image_url", image_url: { url: "https://img.example.test/a.jpg" } }] },
        { role: "assistant", content: nil,
          tool_calls: [{ id: "r1", type: "function", function: { name: "read", arguments: "{}" } }] },
        { role: "tool", content: "read a.png", tool_call_id: "r1" },
        { role: "user", content: [{ type: "text", text: "[images from tool results]" }, { type: "image_url", image_url: { url: png } }] }
      ]

      chat(messages)

      base64 = { "type" => "image", "source" => { "type" => "base64", "media_type" => "image/png", "data" => "iVBORw0KGgo=" } }
      expect(sent["messages"][0]["content"]).to eq([
        { "type" => "text", "text" => "look" }, base64,
        { "type" => "image", "source" => { "type" => "url", "url" => "https://img.example.test/a.jpg" } }
      ])
      expect(sent["messages"][2]["content"]).to eq([
        { "type" => "tool_result", "tool_use_id" => "r1", "content" => "read a.png" },
        { "type" => "text", "text" => "[images from tool results]" },
        base64.merge("cache_control" => { "type" => "ephemeral" })
      ])
    end

    it "sends a later system message as user text, never the empty text an image-only message carries" do
      answer
      messages = [
        { role: "system", content: "sys" },
        { role: "user", content: [{ type: "text", text: "" }] },
        { role: "assistant", content: "ok" },
        { role: "user", content: [{ type: "text", text: "and?" }] },
        { role: "system", content: "[note] tail" }
      ]

      chat(messages)

      expect(sent["messages"]).to eq([
        { "role" => "user", "content" => [{ "type" => "text", "text" => "(empty)" }] },
        { "role" => "assistant", "content" => [{ "type" => "text", "text" => "ok" }] },
        { "role" => "user", "content" => [{ "type" => "text", "text" => "and?", "cache_control" => { "type" => "ephemeral" } },
                                          { "type" => "text", "text" => "[note] tail" }] }
      ])
    end

    it "keeps tool_result blocks first when a \"[tool results]\" text merges before them, and ids apart" do
      answer
      messages = [
        { role: "user", content: "go" },
        { role: "assistant", content: nil,
          tool_calls: [{ id: "a.b", type: "function", function: { name: "read", arguments: "{}" } },
                       { id: "a_b", type: "function", function: { name: "read", arguments: "{}" } }] },
        { role: "user", content: "[tool results]\nold" },
        { role: "tool", content: "one", tool_call_id: "a.b" },
        { role: "tool", content: "two", tool_call_id: "a_b" }
      ]

      chat(messages)

      last = sent["messages"].last["content"]
      expect(last.map { |block| block["type"] }).to eq(%w[tool_result tool_result text])
      expect(last.first(2).map { |block| block["tool_use_id"] }.uniq.size).to eq(2)
      expect(sent["messages"][1]["content"].map { |block| block["id"] }).to eq(last.first(2).map { |block| block["tool_use_id"] })
    end

    it "sends a malformed tool name back made valid, in saved blocks and calls alike" do
      answer
      bad = "get_weather\n</parameter"
      messages = [
        { role: "user", content: "go" },
        { role: "assistant", content: nil,
          anthropic_content: [{ "type" => "tool_use", "id" => "toolu_1", "name" => bad, "input" => {} }] },
        { role: "tool", content: "Error: unknown tool", tool_call_id: "toolu_1" },
        { role: "assistant", content: nil, tool_calls: [{ id: "c2", type: "function", function: { name: bad, arguments: "{}" } }] },
        { role: "tool", content: "Error: unknown tool", tool_call_id: "c2" }
      ]

      chat(messages)

      names = sent["messages"].select { |m| m["role"] == "assistant" }.map { |m| m["content"].first["name"] }
      expect(names).to eq(["get_weather___parameter"] * 2)
    end

    it "maps a saved tool_use block's id the way its tool_result's is (a provider's id may be invalid to send)" do
      answer
      messages = [
        { role: "user", content: "go" },
        { role: "assistant", content: nil,
          anthropic_content: [{ "type" => "thinking", "thinking" => "t", "signature" => "" },
                              { "type" => "tool_use", "id" => "functions.get_weather:0", "name" => "get_weather",
                                "input" => { "city" => "Paris" } }] },
        { role: "tool", content: "12C", tool_call_id: "functions.get_weather:0" }
      ]

      chat(messages)

      used = sent["messages"][1]["content"].last["id"]
      expect(used).to match(/\A[a-zA-Z0-9_-]+\z/)
      expect(sent["messages"][2]["content"].first["tool_use_id"]).to eq(used)
      expect(sent["messages"][1]["content"].first).to eq("type" => "thinking", "thinking" => "t", "signature" => "")
    end

    it "splits the system prompt at cache_split (the breakpoint on its stable part) and follows cache.ttl" do
      answer
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("cache.ttl").and_return("1h")

      chat([{ role: "system", content: "stable part|tail", cache_split: 12 }, { role: "user", content: "hi" }])

      hour = { "type" => "ephemeral", "ttl" => "1h" }
      expect(sent["system"]).to eq([{ "type" => "text", "text" => "stable part|", "cache_control" => hour },
                                    { "type" => "text", "text" => "tail" }])
      expect(sent["messages"].last["content"].last["cache_control"]).to eq(hour)
      expect(sent.to_s).not_to include("cache_split")
    end

    it "sets no breakpoints on a side request (purpose other than chat)" do
      answer
      side = described_class.new(base_url: server.root_url, host_name: "recap", env: env, stream: false, purpose: "recap",
                                 retries: false)

      side.chat(messages: [{ role: "system", content: "sys" }, { role: "user", content: "hi" }], model: "m")

      expect(sent.to_s).not_to include("cache_control")
    end

    it "passes Messages fields and configured sampling, drops chi's OpenAI-only ones" do
      answer

      chat([{ role: "user", content: "hi" }],
           options: { max_tokens: 50, temperature: 0.7, top_k: 20, reasoning_effort: "high", stream_options: { a: 1 },
                      chat_template_kwargs: { enable_thinking: false }, prompt_cache_key: "s", logprobs: true,
                      top_logprobs: 3, max_completion_tokens: 9, output_config: { effort: "low" } })

      expect(sent.except("messages")).to eq("model" => "m", "max_tokens" => 50, "stream" => false, "temperature" => 0.7,
                                            "top_k" => 20, "output_config" => { "effort" => "low" })
    end

    describe "max_tokens" do
      it "is the model list's max_tokens (capped at 64000) when the options name none, else 64000" do
        server.default("/v1/models", json: { data: [{ id: "small", max_tokens: 8192 }, { id: "big", max_tokens: 128_000 }] })
        3.times { answer }

        %w[small big other].each { |model| chat([{ role: "user", content: "hi" }], model: model) }

        bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)
        expect(bodies.map { |body| body["max_tokens"] }).to eq([8192, 64_000, 64_000])
      end
    end

    describe "headers" do
      it "sends anthropic-version, the Session-Id and no auth header for a host without a key" do
        answer

        chat([{ role: "user", content: "hi" }], session_id: "sess-1")

        request = server.requests.last
        expect(request.header("anthropic-version")).to eq("2023-06-01")
        expect(request.header("session-id")).to eq("sess-1")
        expect(request.header("content-type")).to eq("application/json")
        expect([request.header("x-api-key"), request.header("authorization")]).to eq([nil, nil])
      end

      context "with a key" do
        let(:env) { { "MSG_KEY" => "sk-msg" } }

        it "sends it as x-api-key by default and as Bearer with auth: bearer, never both" do
          2.times { answer }
          bearer = described_class.new(base_url: server.root_url, host_name: "msg", api_key_env: "MSG_KEY", auth: :bearer,
                                       env: env, stream: false, retries: false)
          keyed = described_class.new(base_url: server.root_url, host_name: "msg", api_key_env: "MSG_KEY", env: env,
                                      stream: false, retries: false)

          keyed.chat(messages: [{ role: "user", content: "hi" }], model: "m")
          bearer.chat(messages: [{ role: "user", content: "hi" }], model: "m")

          first, second = server.requests.select { |r| r.path == "/v1/messages" }
          expect([first.header("x-api-key"), first.header("authorization")]).to eq(["sk-msg", nil])
          expect([second.header("x-api-key"), second.header("authorization")]).to eq([nil, "Bearer sk-msg"])
        end
      end
    end
  end

  describe "#chat, streamed" do
    let(:streamed) do
      described_class.new(base_url: server.root_url, host_name: "msg", env: env, sleeper: ->(_seconds) {},
                          retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 1, base_delay: 0.1, max_delay: 1.0))
    end
    let(:deltas) { [] }

    def stream(name, **)
      server.enqueue("/v1/messages", sse: fixture(name))
      streamed.chat(messages: [{ role: "user", content: "hi" }], model: "m", options: { max_tokens: 100 },
                    on_delta: ->(content:, reasoning:, payload:) { deltas << [content, reasoning, payload] }, **)
    end

    it "streams the text, asks for a stream, and passes every event but pings to on_delta" do
      response = stream("text_stream.hand-written.sse")

      expect(sent["stream"]).to be(true)
      expect(response).to have_attributes(text: "Hello! How can I help you today?", reasoning: "", finish_reason: "stop",
                                          model: "claude-opus-5-5")
      expect(deltas.map(&:first).join).to eq(response.text)
      expect(deltas.map { |d| d[2]["type"] }).not_to include("ping")
      expect(response.provider_content).to eq([{ "type" => "text", "text" => "Hello! How can I help you today?" }])
    end

    it "gives the usage from message_start and message_delta, and hands it to on_delta in the OpenAI shape" do
      response = stream("text_stream.hand-written.sse")

      start = JSON.parse(fixture("text_stream.hand-written.sse")[/data: (\{"type":"message_start".*)$/, 1])
      counts = start.dig("message", "usage")
      prompt = counts["input_tokens"] + counts["cache_read_input_tokens"] + counts["cache_creation_input_tokens"]
      expect(response.usage).to eq(Samagotchi::LLM::Usage.new(
        prompt_tokens: prompt, completion_tokens: 12, source: :server,
        cached_tokens: counts["cache_read_input_tokens"],
        cache_write_tokens: counts["cache_creation_input_tokens"]
      ))
      last = deltas.map(&:last).reverse.find { |payload| payload["type"] == "message_delta" }
      expect(last["usage"]).to eq("prompt_tokens" => prompt, "completion_tokens" => 12,
                                  "prompt_tokens_details" => { "cached_tokens" => counts["cache_read_input_tokens"],
                                                               "cache_write_tokens" => counts["cache_creation_input_tokens"] })
      expect(Samagotchi::TokenUsage.from_payload(last)).to have_attributes(prompt_tokens: prompt, completion_tokens: 12)
    end

    it "reads Fireworks' usage: zeros in message_start, every count in the one message_delta" do
      response = stream("fireworks_text_stream.hand-written.sse")

      expect(response).to have_attributes(text: "Hello from Fireworks.", finish_reason: "stop",
                                          model: "accounts/fireworks/models/kimi-k2p5")
      expect(response.usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 812, completion_tokens: 9, source: :server,
                                                              cached_tokens: 640, cache_write_tokens: 0))
    end

    it "assembles thinking with its signature and a tool call from input_json_delta, and marks tool-call events" do
      response = stream("thinking_tool_use_stream.hand-written.sse")

      expect(response.reasoning).to eq("The user wants the weather in Paris. I'll call get_weather.")
      expect(deltas.map { |d| d[1] }.join).to eq(response.reasoning)
      expect(response.tool_calls.map(&:to_h))
        .to eq([{ id: "toolu_01ExampleWeatherParis01", name: "get_weather", arguments: { "city" => "Paris" } }])
      expect(response.finish_reason).to eq("tool_calls")
      thinking, call = response.provider_content
      expect(thinking).to include("type" => "thinking", "thinking" => response.reasoning)
      expect(thinking["signature"]).to start_with("EqQBCkYIBxgCKkBexample")
      expect(call).to eq("type" => "tool_use", "id" => "toolu_01ExampleWeatherParis01", "name" => "get_weather",
                         "input" => { "city" => "Paris" })
      tool_events = deltas.map(&:last).select { |payload| streamed.tool_call_delta?(payload) }
      expect(tool_events.map { |payload| payload["type"] }.uniq).to eq(%w[content_block_start content_block_delta])
      expect(tool_events.size).to eq(4)
    end

    it "gives a thinking block that came without a signature an empty one (sent back, it needs the key)" do
      response = stream("fireworks_thinking_tool_use_stream.hand-written.sse")

      expect(response.provider_content.first)
        .to eq("type" => "thinking", "thinking" => "The user wants the weather in Paris. I'll call get_weather.", "signature" => "")
      expect(response.tool_calls.map { |call| [call.id, call.arguments] }).to eq([["functions.get_weather:0", { "city" => "Paris" }]])
      expect(response.usage).to have_attributes(prompt_tokens: 1210, completion_tokens: 38)
    end

    it "keeps interleaved blocks in their order: thinking, text, tool_use, thinking, tool_use" do
      response = stream("interleaved_stream.hand-written.sse")

      expect(response.provider_content.map { |block| block["type"] }).to eq(%w[thinking text tool_use thinking tool_use])
      expect(response.text).to eq("Let me look at the files first.")
      expect(response.reasoning).to eq("First I should check the file list.And the README too.")
      expect(response.tool_calls.map(&:name)).to eq(%w[execute read])
      expect(response.tool_calls.map(&:arguments)).to eq([{ "command" => "ls" }, { "path" => "README.md" }])
    end

    it "reads Splash's streams: thinking with the empty signature its start carries, then text or two calls" do
      thinking = stream("splash_thinking_stream.sse")
      calls = stream("splash_tool_stream.sse")

      expect(thinking.provider_content.first).to include("type" => "thinking", "signature" => "")
      expect(thinking.text).not_to be_empty
      expect(thinking.finish_reason).to eq("stop")
      expect(calls.tool_calls.map { |call| [call.name, call.arguments] })
        .to eq([["get_weather", { "city" => "Paris" }], ["get_weather", { "city" => "Oslo" }]])
    end

    it "passes a malformed streamed tool name on as it came (the loop's unknown-tool path answers it)" do
      response = stream("splash_tool_stream_bad_name.sse")

      expect(response.tool_calls.map(&:name)).to eq(["get_weather\n</parameter"] * 2)
      expect(response.tool_calls.map(&:arguments)).to eq([{ "city" => "Paris" }, { "city" => "Oslo" }])
    end

    it "takes the empty text block after a thinking cut by max_tokens as no text (finish length)" do
      response = stream("splash_thinking_max_tokens_stream.sse")

      expect(response).to have_attributes(text: "", finish_reason: "length")
      expect(response.reasoning).not_to be_empty
      expect(response.provider_content.map { |block| block["type"] }).to eq(%w[thinking])
    end

    it "takes a budget-capped thinking as a normal turn (finish stop, the answer after it)" do
      response = stream("thinking_budget_capped_stream.hand-written.sse")

      expect(response.finish_reason).to eq("stop")
      expect(response.text).not_to be_empty
      expect(response.reasoning).not_to be_empty
    end

    it "keeps Splash's omitted thinking: no text, the reasoning in the signature" do
      response = stream("splash_omitted_thinking_stream.hand-written.sse")

      thinking = response.provider_content.find { |block| block["type"] == "thinking" }
      expect(thinking["thinking"]).to eq("")
      expect(thinking["signature"]).not_to be_empty
      expect(response.reasoning).to eq("")
    end

    it "ignores pings with prompt progress (not passed on, nothing shown)" do
      response = stream("splash_ping_progress_stream.hand-written.sse")

      expect(deltas.map { |d| d[2]["type"] }).not_to include("ping")
      expect(response.text).not_to be_empty
    end

    it "raises a mid-stream error event by its type" do
      server.default("/v1/messages", sse: fixture("stream_error.hand-written.sse"))

      expect { streamed.chat(messages: [{ role: "user", content: "hi" }], model: "m", options: { max_tokens: 9 }) }
        .to raise_error(Samagotchi::LLM::ProviderError, /overloaded/i)
    end

    it "raises a plain JSON error a 200 carries instead of a stream, and a body with no events" do
      server.enqueue("/v1/messages", body: JSON.generate(type: "error", error: { type: "invalid_request_error",
                                                                                 message: "bad field" }))
      server.enqueue("/v1/messages", body: "nothing here")

      expect { streamed.chat(messages: [{ role: "user", content: "hi" }], model: "m", options: { max_tokens: 9 }) }
        .to raise_error(Samagotchi::LLM::BadRequest, /bad field/)
      expect { streamed.chat(messages: [{ role: "user", content: "hi" }], model: "m", options: { max_tokens: 9 }) }
        .to raise_error(Samagotchi::LLM::ProtocolError, /no stream events/)
    end

    it "retries a 429 after its retry-after header, then streams the answer" do
      waits = []
      adapter = described_class.new(base_url: server.root_url, host_name: "msg", env: env, sleeper: ->(s) { waits << s },
                                    retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 1, base_delay: 0.1,
                                                                                         max_delay: 1.0))
      server.enqueue("/v1/messages", status: 429, json: fixture("error_429.hand-written.json"), headers: { "Retry-After" => "3" })
      server.enqueue("/v1/messages", sse: fixture("text_stream.hand-written.sse"))

      response = adapter.chat(messages: [{ role: "user", content: "hi" }], model: "m", options: { max_tokens: 9 })

      expect(response.text).to eq("Hello! How can I help you today?")
      expect(waits.sum).to eq(3.0)
    end
  end

  describe "the fireworks dialect" do
    let(:env) { { "FW_KEY" => "fw-key" } }
    let(:options) { { dialect: "fireworks", api_key_env: "FW_KEY" } }

    def bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)

    it "sends each level without display (effort carries it), no cache_control anywhere" do
      5.times { answer }

      %i[default off low medium high].each do |level|
        chat([{ role: "system", content: "stable|tail", cache_split: 7 }, { role: "user", content: "hi" }],
             options: { max_tokens: 100, **adapter.thinking_fields(level) })
      end

      expect(bodies.map { |body| body.slice("thinking", "output_config") }).to eq([
        {}, { "thinking" => { "type" => "disabled" } },
        { "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "low" } },
        { "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "medium" } },
        { "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "high" } }
      ])
      expect(bodies.first).to eq(
        "model" => "m", "max_tokens" => 100, "stream" => false,
        "system" => [{ "type" => "text", "text" => "stable|" }, { "type" => "text", "text" => "tail" }],
        "messages" => [{ "role" => "user", "content" => [{ "type" => "text", "text" => "hi" }] }]
      )
      expect(bodies.to_s).not_to include("cache_control")
      expect(bodies.to_s).not_to include("display")
    end

    it "sends the budget form without display to a model that refused adaptive" do
      server.enqueue("/v1/messages", status: 400, json: { type: "error", error: { type: "invalid_request_error",
                                                                                  message: "adaptive thinking is not supported" } })
      answer

      chat([{ role: "user", content: "hi" }], options: { max_tokens: 64_000, **adapter.thinking_fields(:medium) })

      expect(bodies.last["thinking"]).to eq("type" => "enabled", "budget_tokens" => 8192)
    end

    it "sends the key as Bearer only, and the session id as x-session-affinity beside Session-Id" do
      answer

      chat([{ role: "user", content: "hi" }], session_id: "sess-9")

      request = server.requests.last
      expect([request.header("authorization"), request.header("x-api-key")]).to eq(["Bearer fw-key", nil])
      expect([request.header("x-session-affinity"), request.header("session-id")]).to eq(%w[sess-9 sess-9])
    end

    it "sends no affinity header without a session id" do
      answer

      chat([{ role: "user", content: "hi" }])

      expect(server.requests.last.header("x-session-affinity")).to be_nil
    end

    context "with auth: x-api-key" do
      let(:options) { { dialect: "fireworks", api_key_env: "FW_KEY", auth: :x_api_key } }

      it "sends the key the way auth: says" do
        answer

        chat([{ role: "user", content: "hi" }])

        expect([server.requests.last.header("x-api-key"), server.requests.last.header("authorization")]).to eq(["fw-key", nil])
      end
    end
  end

  describe "#list_models" do
    it "reads Anthropic's list page by page (limit, after_id), its window, max_tokens and image input" do
      server.enqueue("/v1/models", json: fixture("models_page1.hand-written.json"))
      server.enqueue("/v1/models", json: fixture("models_page2.hand-written.json"))

      models = adapter.list_models

      expect(models.map(&:id)).to eq(%w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-4-5-20251001])
      expect(models.map(&:context_window)).to eq([1_000_000, 1_000_000, 200_000])
      expect(models.map(&:image_input)).to eq([true, true, true])
      expect(models.last.raw["max_tokens"]).to eq(64_000)
      queries = server.requests.select { |r| r.path == "/v1/models" }.map { |r| r.query_string }
      expect(queries).to eq(["limit=1000", "limit=1000&after_id=claude-sonnet-5-5"])
    end

    it "reads Splash's OpenAI-shaped list (context_length, input_modalities), and answers the window and vision" do
      server.default("/v1/models", json: fixture("splash_models.json"))
      id = "mlx-community/Qwen3.6-35B-A3B-4bit"

      expect(adapter.list_models.map(&:id)).to eq([id])
      expect(adapter.context_window(model: id)).to eq(262_144)
      expect(adapter.image_input(model: id)).to be(true)
    end

    it "says image input false when Anthropic's capabilities say so" do
      server.default("/v1/models", json: { data: [{ id: "txt", max_input_tokens: 9, capabilities: { image_input: { supported: false } } }] })

      expect(adapter.image_input(model: "txt")).to be(false)
    end
  end

  describe "a field the host refuses (in the adapter, once per request, remembered)" do
    def refuse(message)
      server.enqueue("/v1/messages", status: 400, json: { type: "error", error: { type: "invalid_request_error", message: message } })
    end

    def ask(level, max_tokens: 64_000, model: "old")
      chat([{ role: "user", content: "hi" }], model: model, options: { max_tokens: max_tokens, **adapter.thinking_fields(level) })
    end

    def thinking_sent = bodies.map { |body| [body["max_tokens"], body["thinking"], body["output_config"]] }

    def bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)

    it "switches a model that refuses adaptive thinking to the budget form, per level, and keeps it" do
      refuse("thinking.type: adaptive thinking is not supported on this model")
      4.times { answer }

      %i[medium low high].each { |level| ask(level) }
      chat([{ role: "user", content: "hi" }], model: "new", options: { max_tokens: 64_000, **adapter.thinking_fields(:low) })

      summarized = ->(budget) { { "type" => "enabled", "budget_tokens" => budget, "display" => "summarized" } }
      expect(thinking_sent).to eq([
        [64_000, { "type" => "adaptive", "display" => "summarized" }, { "effort" => "medium" }],
        [64_000, summarized.call(8192), nil],
        [64_000, summarized.call(2048), nil],
        [64_000, summarized.call(24_576), nil],
        [64_000, { "type" => "adaptive", "display" => "summarized" }, { "effort" => "low" }]
      ])
      expect(adapter.budget_form?("old")).to be(true)
      expect(adapter.budget_form?("new")).to be(false)
    end

    it "keeps max_tokens above the budget: the budget lowered, or max_tokens raised to 2048 with the smallest budget" do
      refuse("adaptive thinking is not supported")
      3.times { answer }

      ask(:high, max_tokens: 30_000)
      ask(:high, max_tokens: 10_000)
      ask(:low, max_tokens: 1500)

      expect(thinking_sent.drop(1).map { |max, thinking, _| [max, thinking["budget_tokens"]] })
        .to eq([[30_000, 24_576], [10_000, 8976], [2048, 1024]])
    end

    it "drops the cache breakpoints for the host once it refuses cache_control" do
      refuse("cache_control: Extra inputs are not permitted")
      2.times { answer }

      2.times { chat([{ role: "system", content: "sys" }, { role: "user", content: "hi" }], options: { max_tokens: 9 }) }

      expect(bodies.map { |body| body.to_s.include?("cache_control") }).to eq([true, false, false])
    end

    it "retries over-cap max_tokens with the limit the message names, and keeps it for the model" do
      refuse("max_tokens: 100000 > 64000, which is the maximum allowed number of output tokens for old")
      2.times { answer }

      2.times { ask(:default, max_tokens: 100_000) }

      expect(bodies.map { |body| body["max_tokens"] }).to eq([100_000, 64_000, 64_000])
    end

    it "doesn't switch the form for a sampling 400 that mentions effort (the loop's to handle)" do
      refuse("temperature is not supported with adaptive thinking at this effort")

      expect { chat([{ role: "user", content: "hi" }], options: { max_tokens: 9, temperature: 0.7, **adapter.thinking_fields(:low) }) }
        .to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.sampling_refused?).to be(true) }
      expect(bodies.size).to eq(1)
      expect(adapter.budget_form?("m")).to be(false)
    end

    it "leaves any other 400 to the loop (one request): off refused, a context overflow" do
      server.enqueue("/v1/messages", status: 400, json: fixture("error_400_disabled_refused.hand-written.json"))
      server.enqueue("/v1/messages", status: 400, json: fixture("error_400_prompt_too_long.hand-written.json"))

      expect { ask(:off) }.to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.reasoning_refused?).to be(true) }
      expect { ask(:low) }.to raise_error(Samagotchi::LLM::BadRequest) { |e| expect(e.context_overflow?).to be(true) }
      expect(bodies.size).to eq(2)
    end
  end

  describe "#thinking_fields" do
    it "maps chi's levels: default nothing, off disabled, an effort adaptive + summarized at that effort" do
      expect(adapter.thinking_fields(:default)).to eq({})
      expect(adapter.thinking_fields(:off)).to eq(thinking: { type: "disabled" })
      %i[low medium high].each do |level|
        expect(adapter.thinking_fields(level))
          .to eq(thinking: { type: "adaptive", display: "summarized" }, output_config: { effort: level.to_s })
      end
    end
  end

  describe "the response (not streamed)" do
    it "gives a thinking block without a signature an empty one, and leaves a signed one as it is" do
      server.enqueue("/v1/messages", json: { type: "message", role: "assistant", model: "m", stop_reason: "end_turn",
                                             content: [{ type: "thinking", thinking: "hm" },
                                                       { type: "thinking", thinking: "ok", signature: "sig" },
                                                       { type: "text", text: "Done." }] })

      response = chat([{ role: "user", content: "hi" }])

      expect(response.provider_content.first(2)).to eq([{ "type" => "thinking", "thinking" => "hm", "signature" => "" },
                                                        { "type" => "thinking", "thinking" => "ok", "signature" => "sig" }])
    end

    it "gives the text, the usage and the served model, the finish reason in the loop's words" do
      answer

      response = chat([{ role: "user", content: "hi" }])

      expect(response).to have_attributes(text: "PONG", reasoning: "", tool_calls: [], finish_reason: "stop",
                                          model: "mlx-community/Qwen3.6-35B-A3B-4bit")
      expect(response.usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 16, completion_tokens: 3, source: :server))
      expect(response.provider_content).to eq([{ "type" => "text", "text" => "PONG" }])
    end

    it "gives the reasoning, the calls and every block as received (Splash's empty signature kept)" do
      answer("splash_thinking_tool_use.json")

      response = chat([{ role: "user", content: "weather?" }])

      expect(response.reasoning).to start_with("The user wants me to get the weather for Paris and Oslo")
      expect(response.tool_calls.map(&:to_h)).to eq([
        { id: "call_b0de595b7b98b49c2946d22eed433bac_0", name: "get_weather", arguments: { "city" => "Paris" } },
        { id: "call_b0de595b7b98b49c2946d22eed433bac_1", name: "get_weather", arguments: { "city" => "Oslo" } }
      ])
      expect(response.finish_reason).to eq("tool_calls")
      expect(response.provider_content).to eq(JSON.parse(fixture("splash_thinking_tool_use.json"))["content"])
    end

    it "counts cache reads and writes into the prompt, as the rest of chi reads usage" do
      answer("splash_cache_read.json")
      server.enqueue("/v1/messages", json: { type: "message", content: [{ type: "text", text: "x" }],
                                             usage: { input_tokens: 10, cache_read_input_tokens: 100,
                                                      cache_creation_input_tokens: 50, output_tokens: 5 } })

      usage = chat([{ role: "user", content: "hi" }]).usage

      expect(usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 249 + 5952, completion_tokens: 212, source: :server,
                                                     cached_tokens: 5952, cache_write_tokens: 0))
      expect(chat([{ role: "user", content: "hi" }]).usage)
        .to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 160, completion_tokens: 5, source: :server, cached_tokens: 100,
                                          cache_write_tokens: 50))
    end

    it "normalizes the stop reasons and keeps a redacted thinking block with an omitted one" do
      answer("context_window_exceeded.hand-written.json")
      answer("refusal.hand-written.json")
      answer("redacted_thinking.hand-written.json")

      exceeded, refusal, redacted = Array.new(3) { chat([{ role: "user", content: "hi" }]) }

      expect([exceeded.finish_reason, refusal.finish_reason, redacted.finish_reason]).to eq(%w[length refusal stop])
      expect(refusal).to have_attributes(text: "", provider_content: [])
      expect(redacted.provider_content.map { |b| b["type"] }).to eq(%w[redacted_thinking thinking text])
      expect(redacted).to have_attributes(text: "Here is the answer.", reasoning: "")
    end

    it "raises the error a 200 carries, and a body without content as a protocol error" do
      server.enqueue("/v1/messages", json: { type: "error", error: { type: "overloaded_error", message: "busy" } })
      server.enqueue("/v1/messages", json: { type: "message" })

      expect { chat([{ role: "user", content: "hi" }]) }.to raise_error(Samagotchi::LLM::ServerError, /busy/)
      expect { chat([{ role: "user", content: "hi" }]) }.to raise_error(Samagotchi::LLM::ProtocolError, /no content/)
    end

    it "raises the mapped error for an error status (404 unknown model, not retried)" do
      answer("splash_error_404_unknown_model.json", status: 404)

      expect { chat([{ role: "user", content: "hi" }]) }.to raise_error(Samagotchi::LLM::BadRequest, /not found/)
      expect(server.requests.count { |r| r.path == "/v1/messages" }).to eq(1)
    end
  end
end
