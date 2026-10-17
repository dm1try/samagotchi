# frozen_string_literal: true

require "spec_helper"
require "socket"
require "samagotchi/bootstrap/probe"
require_relative "../support/fake_provider_server"

RSpec.describe Samagotchi::Bootstrap::Probe do
  describe ".candidates" do
    def roots(target) = described_class.candidates(target).map { |c| [c.root, c.base, c.url] }

    it "reads host, host:port and an IP as http, port 8080 when none" do
      expect(roots("localhost")).to eq([["http://localhost:8080", "http://localhost:8080/v1", false]])
      expect(roots("192.168.1.29:8081")).to eq([["http://192.168.1.29:8081", "http://192.168.1.29:8081/v1", false]])
      expect(roots("gpu-box:11434")).to eq([["http://gpu-box:11434", "http://gpu-box:11434/v1", false]])
    end

    it "tries a domain without a scheme over https first, then http" do
      expect(roots("api.example.com")).to eq([["https://api.example.com", "https://api.example.com/v1", false],
                                              ["http://api.example.com", "http://api.example.com/v1", false]])
      expect(roots("llm.lan.example:8081").map(&:first)).to eq(%w[https://llm.lan.example:8081 http://llm.lan.example:8081])
    end

    it "uses a URL as given; its path is the OpenAI base" do
      expect(roots("https://openrouter.ai/api/v1")).to eq([["https://openrouter.ai", "https://openrouter.ai/api/v1", true]])
      expect(roots("http://10.0.0.5:8000/")).to eq([["http://10.0.0.5:8000", "http://10.0.0.5:8000/v1", false]])
    end

    it "refuses what isn't a host or http(s) URL" do
      expect { described_class.candidates("ftp://x.example") }.to raise_error(ArgumentError, /http\(s\)/)
      expect { described_class.candidates("") }.to raise_error(ArgumentError)
    end
  end

  describe "#classify" do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    let(:server) { FakeProviderServer.start }
    let(:candidate) { described_class.candidates("127.0.0.1:#{server.port}").first }
    let(:probe) { described_class.new(env: { "FAKE_KEY" => "sk-test" }) }
    let(:models) { { object: "list", data: [{ id: "qwen-a" }, { id: "gemma-b" }] } }

    after { server.stop }

    it "finds llama.cpp by its /props and lists the models" do
      server.default("/props", json: { model_alias: "qwen-a", chat_template: "<|im_start|>", build_info: "b1" })
      server.default("/v1/models", json: models)

      result = probe.classify(candidate)

      expect(result.kind).to eq(:native)
      expect(result.props["model_alias"]).to eq("qwen-a")
      expect(result.models.map(&:id)).to eq(%w[qwen-a gemma-b])
    end

    it "falls back to /props' model_alias when /v1/models isn't served" do
      server.default("/props", json: { model_alias: "only-one", build_info: "b1" })

      expect(probe.classify(candidate).models.map(&:id)).to eq(["only-one"])
    end

    it "calls a server without /props but with /v1/models openai" do
      server.default("/v1/models", json: models)

      result = probe.classify(candidate)

      expect(result.kind).to eq(:openai)
      expect(result.models.map(&:id)).to eq(%w[qwen-a gemma-b])
    end

    it "does not take a /props without llama.cpp's fields as native" do
      server.default("/props", json: { hello: "world" })
      server.default("/v1/models", json: models)

      expect(probe.classify(candidate).kind).to eq(:openai)
    end

    it "says a key is needed on 401, and sends the key's Bearer header when given one" do
      # The OpenAI list, then the Anthropic one: both want a key.
      server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })
      server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })
      server.enqueue("/v1/models", json: models)

      expect(probe.classify(candidate)).to have_attributes(kind: :needs_key, status: 401)
      result = probe.classify(candidate, key_env: "FAKE_KEY")

      expect(result.kind).to eq(:openai)
      expect(server.requests.select { |r| r.path == "/v1/models" }.last.header("Authorization")).to eq("Bearer sk-test")
    end

    it "calls anything else unknown, with its status" do
      expect(probe.classify(candidate)).to have_attributes(kind: :unknown, status: 404)
    end

    it "reports a closed port as unreachable at once, without retrying" do
      port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
      closed = described_class.candidates("127.0.0.1:#{port}").first

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = probe.classify(closed)

      expect(result).to have_attributes(kind: :unreachable, reason: "connection refused")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    end

    it "moves on to the next candidate only when one refuses" do
      port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
      closed = described_class::Candidate.new(root: "http://127.0.0.1:#{port}", base: "http://127.0.0.1:#{port}/v1", url: false)
      server.default("/v1/models", json: models)

      expect(probe.classify_target([closed, candidate]).kind).to eq(:openai)
    end

    it "asks /props about one model" do
      server.default("/props", json: { default_generation_settings: { n_ctx: 4096 } })

      expect(probe.model_props(candidate, "qwen-a").dig("default_generation_settings", "n_ctx")).to eq(4096)
    end

    it "sends User-Agent chi/<version> on every request, and no Authorization for a key variable that is not set" do
      server.enqueue("/props", json: { build_info: "b1" })
      server.default("/v1/models", json: models)

      probe.classify(candidate, key_env: "FAKE_KEY")
      expect(server.requests.map { |r| [r.path, r.header("User-Agent"), r.header("Authorization")] })
        .to eq([["/props", Samagotchi::USER_AGENT, "Bearer sk-test"], ["/v1/models", Samagotchi::USER_AGENT, "Bearer sk-test"]])

      result = probe.classify(candidate, key_env: "UNSET_KEY")
      expect(server.requests.last.path).to eq("/props")
      expect(server.requests.last.header("Authorization")).to be_nil
      expect(result).to have_attributes(kind: :unknown, status: nil,
                                        reason: start_with("#{candidate.host}: set UNSET_KEY (the API key for host #{candidate.host})"))
    end

    it "says a server that doesn't answer in time timed out" do
      listener = TCPServer.new("127.0.0.1", 0)
      silent = described_class.candidates("127.0.0.1:#{listener.addr[1]}").first

      expect(described_class.new(timeout: 0.3).classify(silent)).to have_attributes(kind: :unreachable, reason: "timed out")
    ensure
      listener&.close
    end

    describe "an Anthropic Messages server" do
      let(:anthropic_models) { { data: [{ id: "claude-a", type: "model", max_input_tokens: 200_000 }], has_more: false } }
      let(:anthropic_error) { { type: "error", error: { type: "invalid_request_error", message: "anthropic-version: header is required" } } }

      def model_lists = server.requests.select { |r| r.path == "/v1/models" }

      it "is asked after the OpenAI list's 400, with anthropic-version and x-api-key, not Bearer" do
        server.enqueue("/v1/models", status: 400, json: anthropic_error)
        server.enqueue("/v1/models", json: anthropic_models)

        result = probe.classify(candidate, key_env: "FAKE_KEY")

        expect(result).to have_attributes(kind: :anthropic, dialect: nil, auth: nil)
        expect(result).to be_reached
        expect(result.models.map(&:id)).to eq(["claude-a"])
        listed = model_lists.last
        expect(listed.headers).to include("anthropic-version" => Samagotchi::LLM::AnthropicMessages::API_VERSION,
                                          "x-api-key" => "sk-test")
        expect(listed.header("Authorization")).to be_nil
      end

      it "says a key is needed when both lists answer 401 with none" do
        server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })
        server.enqueue("/v1/models", status: 401, json: { error: { message: "no key" } })

        expect(probe.classify(candidate)).to have_attributes(kind: :needs_key, status: 401)
        expect(model_lists.size).to eq(2)
      end

      it "says the key was refused with the Anthropic list's status after the Bearer retry" do
        server.enqueue("/v1/models", status: 400, json: anthropic_error)
        server.enqueue("/v1/models", status: 401, json: { error: { message: "invalid x-api-key" } })
        server.enqueue("/v1/models", status: 401, json: { error: { message: "invalid x-api-key" } })

        expect(probe.classify(candidate, key_env: "FAKE_KEY")).to have_attributes(kind: :needs_key, status: 401)
        expect(model_lists.map { |r| [r.header("x-api-key"), r.header("Authorization")] })
          .to eq([[nil, "Bearer sk-test"], ["sk-test", nil], [nil, "Bearer sk-test"]])
      end

      it "takes a gateway that wants the key as Bearer: auth :bearer" do
        server.enqueue("/v1/models", status: 403, json: { error: { message: "forbidden" } })
        server.enqueue("/v1/models", status: 401, json: { error: { message: "wants Bearer" } })
        server.enqueue("/v1/models", json: anthropic_models)

        expect(probe.classify(candidate, key_env: "FAKE_KEY")).to have_attributes(kind: :anthropic, auth: :bearer)
        expect(model_lists.last.headers).to include("authorization" => "Bearer sk-test", "anthropic-version" => "2023-06-01")
      end

      it "is not asked after a 404 (a typed URL path lists elsewhere)" do
        typed = described_class.candidates("http://127.0.0.1:#{server.port}/api/v1").first
        server.default("/v1/models", json: anthropic_models)

        expect(probe.classify(typed, key_env: "FAKE_KEY")).to have_attributes(kind: :unknown, status: 404)
        expect(model_lists).to be_empty
      end

      it "keeps the OpenAI result when an anthropic-friendly server lists the OpenAI way" do
        server.default("/v1/models", json: models)

        expect(probe.classify(candidate, key_env: "FAKE_KEY").kind).to eq(:openai)
        expect(model_lists.map { |r| r.header("anthropic-version") }).to eq([nil])
      end

      it "answers with the OpenAI list's failure when the Anthropic one fails otherwise" do
        server.enqueue("/v1/models", status: 400, json: { error: { message: "bad" } })
        server.enqueue("/v1/models", status: 500, json: { error: { message: "down" } })

        expect(probe.classify(candidate, key_env: "FAKE_KEY")).to have_attributes(kind: :unknown, status: 400)
      end

      it "reads Fireworks' model ids as the fireworks dialect, unless --dialect says otherwise" do
        fireworks = { data: [{ id: "accounts/fireworks/models/glm-5" }] }
        server.enqueue("/v1/models", status: 400, json: anthropic_error)
        server.enqueue("/v1/models", json: fireworks)

        expect(probe.classify(candidate, key_env: "FAKE_KEY")).to have_attributes(kind: :anthropic, dialect: "fireworks")

        server.default("/v1/models", json: fireworks)
        expect(probe.classify(candidate, key_env: "FAKE_KEY", api: :anthropic, dialect: "standard"))
          .to have_attributes(kind: :anthropic, dialect: nil)
      end

      it "with api :anthropic asks neither /props nor the Bearer list, and sends a forced dialect's header" do
        server.default("/v1/models", json: anthropic_models)

        expect(probe.classify(candidate, key_env: "FAKE_KEY", api: :anthropic, dialect: "fireworks"))
          .to have_attributes(kind: :anthropic, dialect: "fireworks", auth: nil)
        expect(server.requests.map { |r| [r.path, r.header("x-api-key"), r.header("Authorization"), r.header("anthropic-version")] })
          .to eq([["/v1/models", nil, "Bearer sk-test", "2023-06-01"]])
      end

      it "with api :openai never asks the Anthropic list" do
        server.default("/v1/models", status: 400, json: anthropic_error)

        expect(probe.classify(candidate, key_env: "FAKE_KEY", api: :openai)).to have_attributes(kind: :unknown, status: 400)
        expect(model_lists.size).to eq(1)
      end

      it "passes api and dialect through classify_target" do
        server.default("/v1/models", json: anthropic_models)

        expect(probe.classify_target([candidate], key_env: "FAKE_KEY", api: :anthropic).kind).to eq(:anthropic)
        expect(server.requests.map(&:path)).to eq(["/v1/models"])
      end
    end

    describe "#test_turn" do
      it "counts any 200 with a choice as answered" do
        server.default("/v1/chat/completions", json: { choices: [{ message: { content: "" } }] })

        expect(probe.test_turn(candidate, "qwen-a")).to be_a(Float)
        body = server.requests.last.json
        expect(body).to include("model" => "qwen-a", "max_tokens" => 16, "stream" => false)
      end

      it "raises with the server's error" do
        server.default("/v1/chat/completions", status: 400, json: { error: { message: "model not found" } })

        expect { probe.test_turn(candidate, "nope") }.to raise_error(RuntimeError, "HTTP 400: model not found")
      end

      it "raises with the start of a body that isn't JSON, and sends the key and User-Agent" do
        server.default("/v1/chat/completions", status: 502, body: "  #{"bad gateway " * 30}")

        expect { probe.test_turn(candidate, "m", key_env: "FAKE_KEY") }
          .to raise_error(RuntimeError, "HTTP 502: #{"  #{"bad gateway " * 30}"[0, 200].strip}")
        expect(server.requests.last.headers).to include("user-agent" => Samagotchi::USER_AGENT, "authorization" => "Bearer sk-test",
                                                        "content-type" => "application/json")
      end

      it "posts an Anthropic test turn to /v1/messages and counts a 200 with content" do
        server.default("/v1/messages", json: { type: "message", content: [{ type: "text", text: "ok" }], stop_reason: "max_tokens" })

        expect(probe.test_turn(candidate, "claude-a", key_env: "FAKE_KEY", api: :anthropic)).to be_a(Float)
        request = server.requests.last
        expect(request.path).to eq("/v1/messages")
        expect(request.headers).to include("anthropic-version" => "2023-06-01", "x-api-key" => "sk-test",
                                           "content-type" => "application/json")
        expect(request.header("Authorization")).to be_nil
        expect(request.json).to eq("model" => "claude-a", "max_tokens" => 16,
                                   "messages" => [{ "role" => "user", "content" => described_class::TEST_PROMPT }])
      end

      it "sends an Anthropic test turn's key as Bearer for auth :bearer or the fireworks dialect" do
        server.default("/v1/messages", json: { content: [{ type: "text", text: "ok" }] })

        probe.test_turn(candidate, "m", key_env: "FAKE_KEY", api: :anthropic, auth: :bearer)
        probe.test_turn(candidate, "m", key_env: "FAKE_KEY", api: :anthropic, dialect: "fireworks")

        expect(server.requests.map { |r| [r.header("Authorization"), r.header("x-api-key")] })
          .to eq([["Bearer sk-test", nil], ["Bearer sk-test", nil]])
      end

      it "raises with an Anthropic error's message, its status and path" do
        server.default("/v1/messages", status: 400,
                                       json: { type: "error", error: { type: "invalid_request_error", message: "model: not found" } })

        expect { probe.test_turn(candidate, "nope", key_env: "FAKE_KEY", api: :anthropic) }
          .to raise_error(described_class::TestFailed, "HTTP 400: model: not found") { |e|
            expect([e.status, e.path]).to eq([400, "/v1/messages"])
          }
      end

      it "says a 404 on /chat/completions with its status and path" do
        expect { probe.test_turn(candidate, "m") }
          .to raise_error(described_class::TestFailed) { |e| expect([e.status, e.path]).to eq([404, "/v1/chat/completions"]) }
      end

      it "names the server when it can't be reached" do
        port = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }
        closed = described_class.candidates("127.0.0.1:#{port}").first

        expect { probe.test_turn(closed, "m") }.to raise_error(RuntimeError, "connection refused (127.0.0.1:#{port})")
      end
    end
  end

  describe ".fireworks?" do
    def candidate(target) = described_class.candidates(target).first
    def model(id) = Samagotchi::LLM::ModelInfo.new(id: id, context_window: nil, supports_tools: nil, raw: {})

    it "knows Fireworks by its host or a subdomain" do
      expect(described_class.fireworks?(candidate("https://api.fireworks.ai/inference/v1"))).to be(true)
      expect(described_class.fireworks?(candidate("https://fireworks.ai"))).to be(true)
      expect(described_class.fireworks?(candidate("https://notfireworks.ai"))).to be(false)
      expect(described_class.fireworks?(candidate("https://fireworks.ai.example.com"))).to be(false)
    end

    it "knows Fireworks by a model id in its accounts/fireworks/ namespace" do
      gateway = candidate("https://llm.example.com")
      expect(described_class.fireworks?(gateway, [model("claude-a"), model("accounts/fireworks/models/kimi")])).to be(true)
      expect(described_class.fireworks?(gateway, [model("claude-a")])).to be(false)
    end
  end

  describe ".api_root" do
    it "is the OpenAI base without its trailing /v1" do
      roots = ["https://api.anthropic.com", "https://api.anthropic.com/v1", "https://api.fireworks.ai/inference/v1",
               "10.0.0.5:8082"].map { |t| described_class.api_root(described_class.candidates(t).first) }

      expect(roots).to eq(%w[https://api.anthropic.com https://api.anthropic.com https://api.fireworks.ai/inference
                             http://10.0.0.5:8082])
    end
  end

  describe "#scan_local" do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    it "returns the ports that answer as a model server" do
      server = FakeProviderServer.start
      server.default("/v1/models", json: { data: [{ id: "m" }] })
      closed = TCPServer.open("127.0.0.1", 0) { |s| s.addr[1] }

      found = described_class.new.scan_local(ports: [closed, server.port])

      expect(found.map { |r| r.candidate.port }).to eq([server.port])
    ensure
      server&.stop
    end
  end
end
