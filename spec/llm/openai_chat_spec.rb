# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/openai_chat"
require "samagotchi/cancellation_controller"
require "samagotchi/host_registry"
require_relative "../support/fake_provider_server"

RSpec.describe Samagotchi::LLM::OpenAIChat do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:env) { {} }
  let(:adapter) do
    described_class.new(base_url: server.base_url, host_name: "box", env: env, sleeper: ->(_seconds) {},
                        retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 1, base_delay: 0.1, max_delay: 1.0))
  end
  let(:messages) { [{ role: "system", content: "sys" }, { role: "user", content: "hi" }] }
  let(:tools) do
    [{ type: "function", function: { name: "execute", description: "Run a command.",
                                     parameters: { type: "object", properties: { command: { type: "string" } } } } }]
  end

  after { server.stop }

  def replay(fixture)
    server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture(fixture))
  end

  describe "#chat, streamed" do
    it "assembles the text, the reasoning, the usage and the finish reason, calling on_delta per chunk" do
      replay("text_stream.sse")
      deltas = []

      response = adapter.chat(messages: messages, tools: tools, model: "m",
                              on_delta: ->(content:, reasoning:, payload:) { deltas << [content, reasoning, payload] })

      expect(response.text).to eq("PONG")
      expect(response.reasoning).to start_with("The user wants me to reply with exactly")
      expect(response.tool_calls).to eq([])
      expect(response.finish_reason).to eq("stop")
      expect(response.usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 295, completion_tokens: 18, source: :server))
      expect(deltas.map(&:first).join).to eq("PONG")
      expect(deltas.map { |delta| delta[1] }.join).to eq(response.reasoning)
      expect(deltas.last[2]).to include("usage")
    end

    it "sends the chat request: streamed with usage, the tools, temperature 0, no auth header" do
      replay("text_stream.sse")

      adapter.chat(messages: messages, tools: tools, model: "m")

      request = server.requests.last
      expect(request.path).to eq("/v1/chat/completions")
      expect(request.json).to include(
        "model" => "m", "stream" => true, "stream_options" => { "include_usage" => true },
        "tool_choice" => "auto", "temperature" => 0.0,
        "messages" => [{ "role" => "system", "content" => "sys" }, { "role" => "user", "content" => "hi" }]
      )
      expect(request.json["tools"].first.dig("function", "name")).to eq("execute")
      expect(request.header("authorization")).to be_nil
    end

    it "omits tools and tool_choice when there are none, and merges extra options" do
      replay("text_stream.sse")

      adapter.chat(messages: messages, tools: [], model: "m", options: { max_tokens: 512 })

      expect(server.requests.last.json).not_to include("tools", "tool_choice")
      expect(server.requests.last.json["max_tokens"]).to eq(512)
    end

    it "keeps multi-part content as given" do
      replay("text_stream.sse")
      parts = [{ type: "text", text: "look" }, { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }]

      adapter.chat(messages: [{ role: "user", content: parts }], tools: [], model: "m")

      expect(server.requests.last.json["messages"].first["content"]).to eq(JSON.parse(JSON.generate(parts)))
    end

    it "assembles a tool call from its deltas" do
      replay("tool_call_stream.sse")

      response = adapter.chat(messages: messages, tools: tools, model: "m")

      expect(response.tool_calls).to eq([
        Samagotchi::LLM::ToolCall.new(id: "5JY8tS6JPCad0Qah84p5iPHXABEaPiRI", name: "execute", arguments: { "command" => "echo hi" })
      ])
      expect(response.finish_reason).to eq("tool_calls")
    end

    it "assembles parallel tool calls by index" do
      replay("parallel_tool_calls_stream.sse")

      calls = adapter.chat(messages: messages, tools: tools, model: "m").tool_calls

      expect(calls.map(&:arguments)).to eq([{ "command" => "echo a" }, { "command" => "echo b" }])
      expect(calls.map(&:id).uniq.size).to eq(2)
    end

    it "keeps text written before a tool call" do
      replay("reasoning_tool_stream.sse")

      response = adapter.chat(messages: messages, tools: tools, model: "m")

      expect(response.text).to eq("The command to list files is `ls`.\n\n")
      expect(response.tool_calls.map(&:name)).to eq(["execute"])
    end

    it "keeps arguments that are not JSON as the raw string" do
      server.enqueue("/v1/chat/completions", sse: [
        %(data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"execute","arguments":"{\\"command\\": oops"}}]}}]}\n\n),
        %(data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}\n\n),
        "data: [DONE]\n\n"
      ])

      call = adapter.chat(messages: messages, tools: tools, model: "m").tool_calls.first

      expect(call.arguments).to eq('{"command": oops')
    end

    it "reports no usage when the server sends none" do
      server.enqueue("/v1/chat/completions", sse: [
        %(data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}]}\n\n), "data: [DONE]\n\n"
      ])

      expect(adapter.chat(messages: messages, tools: [], model: "m").usage).to eq(Samagotchi::LLM::Usage.none)
    end
  end

  describe "#chat, not streamed" do
    let(:adapter) { described_class.new(base_url: server.base_url, host_name: "box", env: env, stream: false, retries: false) }

    it "reads the whole message" do
      server.enqueue("/v1/chat/completions", json: FakeProviderServer.fixture("text_sync.json"))

      response = adapter.chat(messages: messages, tools: [], model: "m")

      expect(response.text).to eq("PONG")
      expect(response.reasoning).to include("reply with exactly")
      expect(response.usage.source).to eq(:server)
      expect(server.requests.last.json).not_to include("stream_options")
      expect(server.requests.last.json["stream"]).to be(false)
    end

    it "raises ProtocolError for a body without a message" do
      server.enqueue("/v1/chat/completions", json: { choices: [] })

      expect { adapter.chat(messages: messages, tools: [], model: "m") }.to raise_error(Samagotchi::LLM::ProtocolError)
    end
  end

  describe "API keys" do
    let(:keyed) { described_class.new(base_url: server.base_url, host_name: "fw", api_key_env: "EXAMPLE_KEY", env: env) }

    it "sends the key from the named variable as a bearer token" do
      env["EXAMPLE_KEY"] = "sk-test-123"
      replay("text_stream.sse")

      keyed.chat(messages: messages, tools: [], model: "m")

      expect(server.requests.last.header("authorization")).to eq("Bearer sk-test-123")
    end

    it "raises AuthError naming the variable when it is not set, without a request" do
      expect { keyed.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::AuthError, /EXAMPLE_KEY/) { |error| expect(error.host).to eq("fw") }
      expect(server.requests).to be_empty
    end

    it "never puts the key in an error message" do
      env["EXAMPLE_KEY"] = "sk-test-123"
      server.default("/v1/chat/completions", status: 401, json: FakeProviderServer.fixture("error_401.hand-written.json"))

      expect { keyed.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::AuthError) { |error| expect(error.message).not_to include("sk-test-123") }
    end
  end

  describe "errors" do
    it "maps the context overflow 400" do
      server.default("/v1/chat/completions", status: 400, json: FakeProviderServer.fixture("error_400.json"))

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::BadRequest) { |error| expect(error).to be_context_overflow }
    end

    it "raises ProtocolError for a malformed stream line" do
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("malformed.hand-written.sse"))

      expect { adapter.chat(messages: messages, tools: [], model: "m") }.to raise_error(Samagotchi::LLM::ProtocolError)
    end

    it "raises ProtocolError for a 200 whose body has no stream events" do
      server.enqueue("/v1/chat/completions", json: "{not json")

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::ProtocolError, /no stream events.*\{not json/)
    end

    it "raises the server's mid-stream error once the retries run out" do
      server.default("/v1/chat/completions", sse: FakeProviderServer.fixture("stream_error.hand-written.sse"))

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::ServerError, /slot unavailable/) { |error| expect(error.attempts).to eq(2) }
    end

    it "retries an upstream error sent as the first event of a 200 (OpenRouter), then answers" do
      replay("openrouter_stream_error_503.hand-written.sse")
      replay("text_stream.sse")
      retries = []

      response = adapter.chat(messages: messages, tools: [], model: "m", on_retry: ->(**event) { retries << event })

      expect(response.text).to eq("PONG")
      expect(retries.map { |event| event[:error_class] }).to eq(["Samagotchi::LLM::ServerError"])
      expect(server.requests.size).to eq(2)
    end

    it "retries an in-stream 429 as a rate limit" do
      server.enqueue("/v1/chat/completions", sse: "data: {\"choices\":[],\"error\":{\"code\":429,\"message\":\"slow down\"}}\n\n")
      replay("text_stream.sse")
      retries = []

      adapter.chat(messages: messages, tools: [], model: "m", on_retry: ->(**event) { retries << event })

      expect(retries.map { |event| event[:error_class] }).to eq(["Samagotchi::LLM::RateLimited"])
    end

    it "does not retry an error that follows streamed text; the retry would repeat it" do
      text = FakeProviderServer.sse_events(FakeProviderServer.fixture("text_stream.sse"))
                               .find { |event| event.include?('"content":"P') }
      server.default("/v1/chat/completions", sse: [text, "data: {\"choices\":[],\"error\":{\"code\":503,\"message\":\"gone\"}}\n\n"])
      deltas = []

      expect { adapter.chat(messages: messages, tools: [], model: "m", on_delta: ->(content:, **) { deltas << content }) }
        .to raise_error(Samagotchi::LLM::ServerError, /gone/) { |error| expect(error.attempts).to eq(1) }
      expect(deltas.join).not_to be_empty
      expect(server.requests.size).to eq(1)
    end

    it "cancels a stream in flight" do
      controller = Samagotchi::CancellationController.new
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.sse_events(FakeProviderServer.fixture("text_stream.sse")).first(3),
                                             hold: true)

      expect {
        adapter.chat(messages: messages, tools: [], model: "m", cancel_controller: controller,
                     on_delta: ->(**) { controller.cancel!(:ctrl_c) })
      }.to raise_error(Samagotchi::LLM::RequestCancelled)
    end
  end

  describe "#list_models" do
    it "reads llama.cpp's list, with the running window from meta.n_ctx" do
      server.default("/v1/models", json: FakeProviderServer.fixture("models.json"))

      models = adapter.list_models

      expect(models.map(&:id)).to eq(["ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M"])
      expect(models.first.context_window).to eq(128_000)
      expect(models.first.raw).to include("owned_by" => "llamacpp")
    end

    it "reads context_length, context_window or max_model_len, and tool support, and follows pages" do
      server.enqueue("/v1/models", json: { data: [{ id: "a", context_length: 32_768, supported_parameters: ["tools"] }],
                                           has_more: true, last_id: "a" })
      server.enqueue("/v1/models", json: { data: [{ id: "b", max_model_len: 8192 }, { id: "c" }], has_more: false })

      models = adapter.list_models

      expect(models.map { |m| [m.id, m.context_window, m.supports_tools] })
        .to eq([["a", 32_768, true], ["b", 8192, nil], ["c", nil, nil]])
      expect(server.requests.size).to eq(2)
    end

    it "answers context_window from the listed model, listing once" do
      server.default("/v1/models", json: FakeProviderServer.fixture("models.json"))

      2.times { expect(adapter.context_window(model: "ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M")).to eq(128_000) }
      expect(adapter.context_window(model: "unknown")).to be_nil
      expect(server.requests.size).to eq(1)
    end

    it "answers nil when the list can't be read" do
      server.default("/v1/models", status: 500, json: { error: { message: "down" } })

      expect(adapter.context_window(model: "m")).to be_nil
    end
  end

  it "is built from a host entry" do
    registry = Samagotchi::HostRegistry.new(hosts_config: {
      "fw" => { name: "fw", host: "api.example.test", port: 443, scheme: "https", api: :openai,
                url: "https://api.example.test/inference/v1", api_key_env: "FW_KEY" }
    })

    built = described_class.for(registry.entries["fw"])

    expect(built.base_url).to eq("https://api.example.test/inference/v1")
    expect(built.host_name).to eq("fw")
    expect(built.api_key_env).to eq("FW_KEY")
  end
end
