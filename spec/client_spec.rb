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

    context "with the mlx transport" do
      it "posts a raw prompt to /v1/completions and joins streamed text" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
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
        allow(response).to receive(:read_body)
          .and_yield("data: {\"choices\":[{\"text\":\"Hel\"}]}\n")
          .and_yield("data: {\"choices\":[{\"text\":\"lo\"}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", stop: ["done"], n_predict: 128, model: "Qwen3-14B-Instruct")

        expect(result).to eq("Hello")
        expect(request.path).to eq("/v1/completions")
        expect(request.body).to include('"prompt":"prompt"')
        expect(request.body).to include('"stop":["done"]')
        expect(request.body).to include('"max_tokens":128')
        expect(request.body).not_to include('"n_predict"')
      end

      it "omits max_tokens when n_predict is not provided" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt")).to eq("ok")
        expect(request.body).not_to include('"max_tokens"')
      end

      it "never forwards model, since mlx-lm treats it as a path/repo to (re)load" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt", model: "mlx-community/Qwen3-14B-Instruct")).to eq("ok")
        expect(request.body).not_to include('"model"')
      end

      it "emits chunk callbacks and ignores the [DONE] sentinel" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
        http = instance_double(Net::HTTP)
        response = double("response")
        chunks = []

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) { |_request, &block| block.call(response) }
        allow(response).to receive(:read_body)
          .and_yield("data: {\"choices\":[{\"text\":\"Hi\"}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] })

        expect(result).to eq("Hi")
        expect(chunks).to eq(["Hi"])
      end

      it "reads the transport from SAMAGOTCHI_SERVER_TRANSPORT when not passed explicitly" do
        ENV["SAMAGOTCHI_SERVER_TRANSPORT"] = "mlx"
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt")).to eq("ok")
        expect(request.path).to eq("/v1/completions")
      ensure
        ENV.delete("SAMAGOTCHI_SERVER_TRANSPORT")
      end

      it "labels errors with mlx instead of llama.cpp" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
          .and_raise(JSON::ParserError.new("bad json"))

        expect { client.complete("prompt") }
          .to raise_error(RuntimeError, /mlx request failed \(localhost:8080\): .*bad json/)
      end
    end

    context "with the omlx transport" do
      it "posts a raw prompt to /v1/completions and joins streamed text" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
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
          .and_yield("data: {\"choices\":[{\"text\":\"Hel\"}]}\n")
          .and_yield("data: {\"choices\":[{\"text\":\"lo\"}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", stop: ["done"], n_predict: 128, model: "Qwen3.6")

        expect(result).to eq("Hello")
        expect(request.path).to eq("/v1/completions")
        expect(request.body).to include('"prompt":"prompt"')
        expect(request.body).to include('"stop":["done"]')
        expect(request.body).to include('"max_tokens":128')
        expect(request.body).not_to include('"n_predict"')
        expect(request.body).not_to include('"model"')
      end

      it "omits max_tokens when n_predict is not provided" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt")).to eq("ok")
        expect(request.body).not_to include('"max_tokens"')
      end

      it "never forwards model, since oMLX treats it as a path/repo to (re)load" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt", model: "omlx-community/Qwen3.6")).to eq("ok")
        expect(request.body).not_to include('"model"')
      end

      it "ignores a leading keepalive chunk and still joins text correctly" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        http = instance_double(Net::HTTP)
        response = double("response")
        chunks = []

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) { |_request, &block| block.call(response) }
        allow(response).to receive(:read_body)
          .and_yield("data: {\"model\":\"keepalive\",\"choices\":[{\"text\":\"\"}]}\n")
          .and_yield("data: {\"choices\":[{\"text\":\"Hi\"}]}\n")
          .and_yield("data: [DONE]\n")

        result = client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] })

        expect(result).to eq("Hi")
        expect(chunks.join).to eq("Hi")
      end

      it "preserves raw tool-call markers verbatim for KernelLoop parsing" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        http = instance_double(Net::HTTP)
        response = double("response")

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) { |_request, &block| block.call(response) }
        allow(response).to receive(:read_body).and_yield(
          "data: {\"choices\":[{\"text\":\"Hi <tool_call><|tool_call>\\n\"}]}\n"
        )

        result = client.complete("prompt")

        expect(result).to include("<tool_call>")
        expect(result).to include("<|tool_call>")
      end

      it "reads the transport from SAMAGOTCHI_SERVER_TRANSPORT when not passed explicitly" do
        ENV["SAMAGOTCHI_SERVER_TRANSPORT"] = "omlx"
        client = described_class.new(host: "localhost", port: 8000)
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
        allow(response).to receive(:read_body).and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")

        expect(client.complete("prompt")).to eq("ok")
        expect(request.path).to eq("/v1/completions")
        expect(client.instance_variable_get(:@transport)).to eq(:omlx)
      ensure
        ENV.delete("SAMAGOTCHI_SERVER_TRANSPORT")
      end

      it "resolves uppercase and whitespace-padded values to :omlx" do
        expect(described_class.new(transport: "OMLX").instance_variable_get(:@transport)).to eq(:omlx)
        expect(described_class.new(transport: " omlx ").instance_variable_get(:@transport)).to eq(:omlx)
      end

      it "labels errors with omlx instead of llama.cpp" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_raise(JSON::ParserError.new("bad json"))

        expect { client.complete("prompt") }
          .to raise_error(RuntimeError, /omlx request failed \(localhost:8000\): .*bad json/)
      end
    end
  end

  describe "#list_models" do
    it "returns the discovered models from /models" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = instance_double(Net::HTTPResponse, body: '{"data":[{"id":"ggml-org/gemma-4-26b-a4b-it-GGUF:Q4_K_M","status":"loaded"}]}')

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request).and_return(response)

      result = client.list_models

      expect(result).to eq([
        { "id" => "ggml-org/gemma-4-26b-a4b-it-GGUF:Q4_K_M", "status" => "loaded" }
      ])
    end

    it "raises RetryExhausted after retry budget is exhausted" do
      client = described_class.new(host: "localhost", port: 8080)
      allow(client).to receive(:wait_with_cancellation)
      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_raise(Net::OpenTimeout)

      expect { client.list_models }
        .to raise_error(described_class::RetryExhausted) do |error|
          expect(error.attempts).to eq(6)
          expect(error.last_error).to be_a(Net::OpenTimeout)
        end
    end

    context "with the mlx transport" do
      it "returns the discovered models from /v1/models" do
        client = described_class.new(host: "localhost", port: 8080, transport: :mlx)
        http = instance_double(Net::HTTP)
        request = nil
        response = instance_double(Net::HTTPResponse, body: '{"object":"list","data":[{"id":"mlx-community/Qwen3-14B-Instruct","object":"model","created":1}]}')

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) do |built_request|
          request = built_request
          response
        end

        result = client.list_models

        expect(request.path).to eq("/v1/models")
        expect(result).to eq([
          { "id" => "mlx-community/Qwen3-14B-Instruct", "object" => "model", "created" => 1 }
        ])
      end
    end

    context "with the omlx transport" do
      it "returns the discovered models from /v1/models" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        http = instance_double(Net::HTTP)
        request = nil
        response = instance_double(Net::HTTPResponse, body: '{"object":"list","data":[{"id":"omlx-community/Qwen3.6","object":"model","created":1}]}')

        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) do |built_request|
          request = built_request
          response
        end

        result = client.list_models

        expect(request.path).to eq("/v1/models")
        expect(result).to eq([
          { "id" => "omlx-community/Qwen3.6", "object" => "model", "created" => 1 }
        ])
      end
    end
  end
end
