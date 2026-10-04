# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/openai_chat"
require "samagotchi/cancellation_controller"
require "samagotchi/host_registry"
require_relative "../support/fake_provider_server"
require "fileutils"
require "tmpdir"

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

  describe "#image_input" do
    it "reads OpenRouter's input_modalities and llama.cpp's multimodal capability" do
      server.default("/v1/models", json: { data: [
        { id: "vis", architecture: { input_modalities: %w[text image] } },
        { id: "txt", architecture: { input_modalities: %w[text] } },
        { id: "local", capabilities: %w[completion multimodal] },
        { id: "plain" }
      ] })

      expect(%w[vis txt local plain nope].map { |m| adapter.image_input(model: m) }).to eq([true, false, true, nil, nil])
    end

    it "answers nil when the listing fails" do
      server.default("/v1/models", status: 500, json: { error: { message: "down" } })
      expect(adapter.image_input(model: "vis")).to be_nil
    end
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

    it "reports the model the server says answered, whatever name was asked for" do
      replay("text_stream.sse")

      response = adapter.chat(messages: messages, tools: tools, model: "unsloth/Qwen3.6")

      expect(response.model).to eq("ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M")
    end

    it "reports the provider the server says served it (OpenRouter), nil when it says none" do
      server.enqueue("/v1/chat/completions", sse: [
        %(data: {"choices":[{"index":0,"delta":{"content":"hi"},"finish_reason":"stop"}],"provider":"Fireworks"}\n\n),
        "data: [DONE]\n\n"
      ])

      expect(adapter.chat(messages: messages, tools: [], model: "m").provider).to eq("Fireworks")

      replay("text_stream.sse")

      expect(adapter.chat(messages: messages, tools: [], model: "m").provider).to be_nil
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

    describe "sampling options" do
      let(:log_dir) { Dir.mktmpdir("samagotchi-log") }
      let(:log_path) { File.join(log_dir, "chi.log") }
      after do
        Samagotchi::Log.reset!
        FileUtils.remove_entry(log_dir)
      end

      def stream_lines
        File.open(log_path) { |io| Samagotchi::LogLine.each_record(io).select { |r| r.event == "stream" } }
      end

      it "sends configured keys, a configured temperature replacing 0.0 (one temperature key), and logs them" do
        Samagotchi::Log.configure(path: log_path, level: :info)
        replay("text_stream.sse")

        adapter.chat(messages: messages, tools: tools, model: "m",
                     options: { temperature: 0.6, presence_penalty: 1.5, chat_template_kwargs: { enable_thinking: false } })

        request = server.requests.last
        expect(request.body.scan('"temperature"').length).to eq(1)
        expect(request.json).to include("temperature" => 0.6, "presence_penalty" => 1.5,
                                        "chat_template_kwargs" => { "enable_thinking" => false }, "model" => "m", "stream" => true)
        expect(stream_lines.last.fields).to include(
          "sampling" => 'temperature=0.6 presence_penalty=1.5 chat_template_kwargs={"enable_thinking":false}'
        )
      end

      it "leaves out a key set to nil (the provider's default temperature)" do
        replay("text_stream.sse")

        adapter.chat(messages: messages, tools: tools, model: "m", options: { temperature: nil })

        expect(server.requests.last.json).not_to have_key("temperature")
      end

      it "sends and logs temperature 0.0 without options" do
        Samagotchi::Log.configure(path: log_path, level: :info)
        replay("text_stream.sse")

        adapter.chat(messages: messages, tools: tools, model: "m")

        expect(server.requests.last.json.keys).to contain_exactly("model", "messages", "temperature", "stream",
                                                                  "stream_options", "tools", "tool_choice")
        expect(stream_lines.last.fields).to include("sampling" => "temperature=0.0")
        expect(stream_lines.last.fields).not_to have_key("cache")
      end

      describe "prompt-cache breakpoints" do
        let(:claude) { "anthropic/claude-sonnet-5.5" }
        let(:marked) { { "type" => "text", "cache_control" => { "type" => "ephemeral" } } }

        def chat_adapter(remote: true, purpose: "chat")
          described_class.new(base_url: server.base_url, host_name: "box", env: env, sleeper: ->(_seconds) {},
                              retries: false, remote: remote, purpose: purpose)
        end

        it "marks the system and the last message of a Claude chat request on a remote host, and logs cache=on" do
          Samagotchi::Log.configure(path: log_path, level: :info)
          replay("text_stream.sse")

          chat_adapter.chat(messages: messages, tools: tools, model: claude)

          sent = server.requests.last.json["messages"]
          expect(sent.map { |m| m["content"] }).to eq([[marked.merge("text" => "sys")], [marked.merge("text" => "hi")]])
          expect(stream_lines.last.fields).to include("cache" => "on", "model" => claude)
        end

        it "sends the messages as given for a local host, a side ask or another model" do
          [[chat_adapter(remote: false), claude], [chat_adapter(purpose: "recap"), claude],
           [chat_adapter, "deepseek/deepseek-v4.1-flash"]].each do |client, model|
            replay("text_stream.sse")
            client.chat(messages: messages, tools: tools, model: model)
            expect(server.requests.last.json["messages"]).to eq([{ "role" => "system", "content" => "sys" },
                                                                 { "role" => "user", "content" => "hi" }])
          end
        end
      end
    end

    describe "max_tokens on OpenRouter" do
      def entry(url) = Samagotchi::HostRegistry::HostEntry.new(name: "or", host: "h", port: 1, api: :openai, url: url)

      it "is set for an OpenRouter host only" do
        expect(described_class.for(entry("https://openrouter.ai/api/v1")).default_max_tokens)
          .to eq(described_class::OPENROUTER_MAX_TOKENS)
        expect(described_class.for(entry("https://api.example.com/v1")).default_max_tokens).to be_nil
        expect(described_class.for(entry("http://192.168.1.29:8081/v1")).default_max_tokens).to be_nil
      end

      it "sends the default when the request names none, and the request's own value over it" do
        capped = described_class.new(base_url: server.base_url, host_name: "or", env: env, retries: false,
                                     default_max_tokens: 32_768)
        replay("text_stream.sse")
        capped.chat(messages: messages, tools: [], model: "m")
        expect(server.requests.last.json["max_tokens"]).to eq(32_768)

        replay("text_stream.sse")
        capped.chat(messages: messages, tools: [], model: "m", options: { max_tokens: 200 })
        expect(server.requests.last.json["max_tokens"]).to eq(200)
      end
    end

    it "sends the session id as a Session-Id header, and no header without one" do
      replay("text_stream.sse")
      adapter.chat(messages: messages, tools: [], model: "m", session_id: "abc-123")
      expect(server.requests.last.header("session-id")).to eq("abc-123")

      replay("text_stream.sse")
      adapter.chat(messages: messages, tools: [], model: "m")
      expect(server.requests.last.header("session-id")).to be_nil
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

    it "scrubs invalid UTF-8 in the text parts of multi-part content" do
      replay("text_stream.sse")
      parts = [{ type: "text", text: "bad \xE2\x80 byte".dup.force_encoding("UTF-8") },
               { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }]

      adapter.chat(messages: [{ role: "user", content: parts }], tools: [], model: "m")

      sent = server.requests.last.json["messages"].first["content"]
      expect(sent.first).to eq("type" => "text", "text" => "bad ? byte")
      expect(sent.last).to eq("type" => "image_url", "image_url" => { "url" => "data:image/png;base64,AA" })
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

    it "reports the model the body names" do
      server.enqueue("/v1/chat/completions", json: FakeProviderServer.fixture("text_sync.json"))

      expect(adapter.chat(messages: messages, tools: [], model: "m").model).to eq("ornith-ai/Ornith-1.5-35B-A3B-GGUF:Q4_K_M")
    end

    it "reports the provider the body names (OpenRouter), nil when it says none" do
      server.enqueue("/v1/chat/completions",
                     json: { choices: [{ message: { content: "hi" } }], model: "m", provider: "Fireworks" })

      expect(adapter.chat(messages: messages, tools: [], model: "m").provider).to eq("Fireworks")

      server.enqueue("/v1/chat/completions", json: { choices: [{ message: { content: "hi" } }], model: "m" })

      expect(adapter.chat(messages: messages, tools: [], model: "m").provider).to be_nil
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

    it "names the variable to check after a 401" do
      env["EXAMPLE_KEY"] = "sk-test-123"
      server.default("/v1/chat/completions", status: 401, json: FakeProviderServer.fixture("error_401.hand-written.json"))

      expect { keyed.chat(messages: messages, tools: [], model: "m") }.to raise_error(Samagotchi::LLM::AuthError) { |error|
        expect(error.summary).to end_with("; check EXAMPLE_KEY (the API key for host fw)")
        expect(error.summary).not_to include("sk-test-123")
      }
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

    it "retries a 200 whose body is a plain JSON 503 error (OpenRouter), then answers" do
      server.enqueue("/v1/chat/completions",
                     json: { error: { code: 503, message: "The model is overloaded, try again" } })
      replay("text_stream.sse")
      retries = []

      response = adapter.chat(messages: messages, tools: [], model: "m", on_retry: ->(**event) { retries << event })

      expect(response.text).to eq("PONG")
      expect(retries.map { |event| event[:error_class] }).to eq(["Samagotchi::LLM::ServerError"])
      expect(retries.first[:error_message]).to include("overloaded")
      expect(server.requests.size).to eq(2)
    end

    it "retries a 200 whose body is a pretty-printed JSON 429 error as a rate limit" do
      server.enqueue("/v1/chat/completions",
                     json: JSON.pretty_generate({ error: { code: 429, message: "Rate limit exceeded" } }))
      replay("text_stream.sse")
      retries = []

      adapter.chat(messages: messages, tools: [], model: "m", on_retry: ->(**event) { retries << event })

      expect(retries.map { |event| event[:error_class] }).to eq(["Samagotchi::LLM::RateLimited"])
    end

    it "fails a 200 whose body is a plain JSON 400-like error with its message, without a retry" do
      server.default("/v1/chat/completions", json: { error: { code: 400, message: "Invalid model id foo" } })

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::BadRequest, /HTTP 400: Invalid model id foo/)
      expect(server.requests.size).to eq(1)
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

    it "fails once, without a retry, when llama.cpp has no mmproj for an image (HTTP 500)" do
      server.default("/v1/chat/completions", status: 500,
                                             json: FakeProviderServer.fixture("llamacpp_error_500_no_mmproj.hand-written.json"))

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::VisionUnsupported) { |error|
          expect(error.summary).to include("host box can't take images", "mmproj", "send text only")
          expect(error.retryable?).to be(false)
        }
      expect(server.requests.size).to eq(1)
    end

    it "maps OpenRouter's 404 for an image to a text-only model" do
      server.default("/v1/chat/completions", status: 404,
                                             json: FakeProviderServer.fixture("openrouter_error_404_no_image.hand-written.json"))

      expect { adapter.chat(messages: messages, tools: [], model: "m") }
        .to raise_error(Samagotchi::LLM::VisionUnsupported, /support image input/) { |error| expect(error.kind).to eq(:vision_unsupported) }
      expect(server.requests.size).to eq(1)
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
