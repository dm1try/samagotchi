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
