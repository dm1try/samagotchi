# frozen_string_literal: true

require "spec_helper"
require "samagotchi/client"

RSpec.describe Samagotchi::Client do
  describe "#complete" do
    it "joins streamed completion chunks into a single response" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      request = nil

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"Hel")
        .and_yield("lo\"}\n")
        .and_yield("data: {\"content\":\" world\"}\n")

      result = client.complete("prompt", stop: ["done"])

      expect(result).to eq("Hello world")
      expect(request.body).to include('"stream":true')
      expect(request.body).to include('"prompt":"prompt"')
      expect(request.body).to include('"stop":["done"]')
      expect(request["Content-Type"]).to eq("application/json")
    end

    it "includes n_predict when provided" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      request = nil

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      result = client.complete("prompt", stop: ["done"], n_predict: 1024)

      expect(result).to eq("ok")
      expect(request.body).to include('"n_predict":1024')
    end

    it "includes model when provided" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      request = nil

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      result = client.complete("prompt", stop: ["done"], model: "Qwen3-14B-Instruct")

      expect(result).to eq("ok")
      expect(request.body).to include('"model":"Qwen3-14B-Instruct"')
    end

    it "omits model when blank" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      request = nil

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      result = client.complete("prompt", stop: ["done"], model: "   ")

      expect(result).to eq("ok")
      expect(request.body).not_to include('"model"')
    end

    it "uses configured timeout values" do
      client = described_class.new(host: "localhost", port: 8080, open_timeout: 2, read_timeout: 1200)
      http = instance_double(Net::HTTP)
      response = double("response")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 2, read_timeout: 1200)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body)

      client.complete("prompt")
    end

    it "invokes on_chunk for each streamed content fragment" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      chunks = []

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"Hel\"}\n")
        .and_yield("data: {\"content\":\"lo\"}\n")

      result = client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] })

      expect(result).to eq("Hello")
      expect(chunks).to eq(["Hel", "lo"])
    end

    it "reads timeout values from environment" do
      ENV["LLAMA_OPEN_TIMEOUT"] = "3"
      ENV["LLAMA_READ_TIMEOUT"] = "900"

      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 3, read_timeout: 900)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body)

      client.complete("prompt")
    ensure
      ENV.delete("LLAMA_OPEN_TIMEOUT")
      ENV.delete("LLAMA_READ_TIMEOUT")
    end

    it "raises a cancellation error when the cancel controller is already cancelled" do
      client = described_class.new(host: "localhost", port: 8080)
      cancel_controller = described_class::CancellationController.new
      cancel_controller.cancel!(:manual)

      expect(Net::HTTP).not_to receive(:start)
      expect { client.complete("prompt", cancel_controller: cancel_controller) }
        .to raise_error(described_class::RequestCancelled) { |error| expect(error.reason).to eq(:manual) }
    end

    it "removes cancel listeners after a successful request" do
      client = described_class.new(host: "localhost", port: 8080)
      cancel_controller = described_class::CancellationController.new
      http = instance_double(Net::HTTP)
      response = double("response")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      expect(client.complete("prompt", cancel_controller: cancel_controller)).to eq("ok")
      expect { cancel_controller.cancel!(:manual) }.not_to raise_error
    end

    it "retries transient network errors and emits retry metadata" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      retries = []
      call_count = 0

      allow(client).to receive(:wait_with_cancellation)
      allow(Net::HTTP).to receive(:start).with("localhost", 8080, open_timeout: 10, read_timeout: 600) do |_host, _port, open_timeout:, read_timeout:, &block|
        call_count += 1
        raise Errno::ECONNREFUSED if call_count == 1

        block.call(http)
      end
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      result = client.complete("prompt", on_retry: ->(event) { retries << event })

      expect(result).to eq("ok")
      expect(retries.length).to eq(1)
      expect(retries.first[:attempt]).to eq(1)
      expect(retries.first[:max_retries]).to eq(5)
      expect(retries.first[:next_delay]).to eq(0.5)
      expect(retries.first[:error_class]).to eq("Errno::ECONNREFUSED")
    end

    it "raises RetryExhausted after retry budget is exhausted" do
      client = described_class.new(host: "localhost", port: 8080)
      allow(client).to receive(:wait_with_cancellation)
      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_raise(Net::OpenTimeout)

      expect { client.complete("prompt") }
        .to raise_error(described_class::RetryExhausted) do |error|
          expect(error.attempts).to eq(6)
          expect(error.last_error).to be_a(Net::OpenTimeout)
        end
    end

    it "does not retry non-network errors" do
      client = described_class.new(host: "localhost", port: 8080)
      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_raise(JSON::ParserError.new("bad json"))

      expect { client.complete("prompt") }
        .to raise_error(RuntimeError, /llama\.cpp request failed \(localhost:8080\): .*bad json/)
    end

    context "with the OpenAI-compatible transport" do
      it "posts to /v1/chat/completions and joins streamed delta content" do
        client = described_class.new(host: "localhost", port: 8000, transport: :openai, model: "qwen3")
        http = instance_double(Net::HTTP)
        response = double("response")
        request = nil

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) do |built_request, &block|
          request = built_request
          block.call(response)
        end
        allow(response).to receive(:read_body)
          .and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n")
          .and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", stop: ["done"], n_predict: 128)

        expect(result).to eq("Hello")
        expect(request.path).to eq("/v1/chat/completions")
        expect(request.body).to include('"model":"qwen3"')
        expect(request.body).to include('"messages":[{"role":"user","content":"prompt"}]')
        expect(request.body).to include('"stop":["done"]')
        expect(request.body).to include('"max_tokens":128')
      end

      it "emits chunk callbacks only for visible delta content" do
        client = described_class.new(host: "localhost", port: 8000, transport: :openai, model: "qwen3")
        http = instance_double(Net::HTTP)
        response = double("response")
        chunks = []

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) { |_request, &block| block.call(response) }
        allow(response).to receive(:read_body)
          .and_yield("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n")
          .and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] })

        expect(result).to eq("Hi")
        expect(chunks).to eq(["Hi"])
      end

      it "adds an authorization header when an API key is configured" do
        client = described_class.new(host: "localhost", port: 8000, transport: :openai, model: "qwen3", api_key: "secret")
        http = instance_double(Net::HTTP)
        response = double("response")
        request = nil

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) do |built_request, &block|
          request = built_request
          block.call(response)
        end
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n")

        expect(client.complete("prompt")).to eq("ok")
        expect(request["Authorization"]).to eq("Bearer secret")
      end

      it "requires a model when using the OpenAI-compatible transport" do
        client = described_class.new(host: "localhost", port: 8000, transport: :openai)

        expect { client.complete("prompt") }
          .to raise_error(ArgumentError, /SAMAGOTCHI_MODEL is required/)
      end
    end
  end
end
