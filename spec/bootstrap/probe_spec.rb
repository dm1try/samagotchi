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
