# frozen_string_literal: true

require "spec_helper"
require "samagotchi/client"
require_relative "support/fake_provider_server"

RSpec.describe Samagotchi::Client do
  describe Samagotchi::Client::Transport do
    it "uses llama.cpp native paths and payload keys" do
      t = described_class.new(:llama_cpp)
      expect(t.label).to eq("llama.cpp")
      expect(t.completion_path).to eq("/completion")
      expect(t.models_path).to eq("/models")
      expect(t.token_limit_key).to eq(:n_predict)
      expect(t.content_from_payload({ "content" => "hi" })).to eq("hi")
    end

    it "uses OpenAI-compatible paths and payload keys for mlx and omlx" do
      %i[mlx omlx].each do |name|
        t = described_class.new(name)
        expect(t.label).to eq(name.to_s)
        expect(t.completion_path).to eq("/v1/completions")
        expect(t.models_path).to eq("/v1/models")
        expect(t.token_limit_key).to eq(:max_tokens)
        expect(t.content_from_payload({ "choices" => [{ "text" => "hi" }] })).to eq("hi")
      end
    end

    it "forwards the model selector verbatim by default (omitting empty/blank)" do
      t = described_class.new(:llama_cpp)
      expect(t.model_for_payload("gemma-4-26b-a4b-it-4bit")).to eq("gemma-4-26b-a4b-it-4bit")
      expect(t.model_for_payload("  spaced  ")).to eq("spaced")
      expect(t.model_for_payload("")).to be_nil
      expect(t.model_for_payload(nil)).to be_nil
    end

    it "defers to an installed model resolver (mlx omits, omlx resolves)" do
      omitting = described_class.new(:mlx, model_resolver: ->(_m) { nil })
      expect(omitting.model_for_payload("anything")).to be_nil

      resolving = described_class.new(:omlx, model_resolver: ->(m) { "mlx-community--#{m}" })
      expect(resolving.model_for_payload("gemma-3-4b")).to eq("mlx-community--gemma-3-4b")
    end
  end

  describe "#complete" do
    it "joins streamed completion chunks into a single response" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response", code: "200")
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

    it "scrubs invalid UTF-8 bytes in the prompt before serializing so a stray bad byte can't abort the turn" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response", code: "200")
      request = nil

      # A tool response that carried a garbled (truncated) em-dash byte is the
      # real crash that surfaced this: JSON#to_json raises on invalid UTF-8.
      conv = [
        { "role" => "system", "content" => "system prompt" },
        { "role" => "tool_response", "content" => "broken dash: \xE2\x80" }
      ]

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      expect { client.complete(conv, stop: ["done"]) }.not_to raise_error
      expect(request.body).not_to include("\xE2\x80")
      expect(request.body).to include('"stream":true')
    end

    it "includes n_predict when provided" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response", code: "200")
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
      response = double("response", code: "200")
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
      response = double("response", code: "200")
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
      response = double("response", code: "200")

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
      response = double("response", code: "200")
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
      ENV["SAMAGOTCHI_SERVER_OPEN_TIMEOUT"] = "3"
      ENV["SAMAGOTCHI_SERVER_READ_TIMEOUT"] = "900"

      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response", code: "200")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 3, read_timeout: 900)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body)

      client.complete("prompt")
    ensure
      ENV.delete("SAMAGOTCHI_SERVER_OPEN_TIMEOUT")
      ENV.delete("SAMAGOTCHI_SERVER_READ_TIMEOUT")
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
      response = double("response", code: "200")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"ok\"}\n")

      expect(client.complete("prompt", cancel_controller: cancel_controller)).to eq("ok")
      expect { cancel_controller.cancel!(:manual) }.not_to raise_error
    end

    it "retries transient network errors and emits retry metadata" do
      client = described_class.new(host: "localhost", port: 8080, sleeper: ->(_seconds) {})
      http = instance_double(Net::HTTP)
      response = double("response", code: "200")
      retries = []
      call_count = 0

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
      client = described_class.new(host: "localhost", port: 8080, sleeper: ->(_seconds) {})
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
        response = double("response", code: "200")
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
        response = double("response", code: "200")
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
        response = double("response", code: "200")
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
        response = double("response", code: "200")
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
        response = double("response", code: "200")
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
      it "posts a raw prompt to /v1/completions and joins streamed text (AC #8)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        # /v1/models is loaded once per completion; stub it so we don't hit a
        # second Net::HTTP.start.
        allow(client).to receive(:list_models).and_return(["mlx-community--gemma-3-4b-it-4bit"])
        http = instance_double(Net::HTTP)
        response = double("response", code: "200")
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

        result = client.complete("prompt", stop: ["done"], n_predict: 128, model: "gemma-3-4b-it-4bit")

        expect(result).to eq("Hello")
        expect(request.path).to eq("/v1/completions")
        expect(request.body).to include('"prompt":"prompt"')
        expect(request.body).to include('"stop":["done"]')
        expect(request.body).to include('"max_tokens":128')
        expect(request.body).not_to include('"n_predict"')
        # resolved full id forwarded (substring match against /v1/models)
        expect(request.body).to include('"model":"mlx-community--gemma-3-4b-it-4bit"')
      end

      it "omits max_tokens when n_predict is not provided" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        http = instance_double(Net::HTTP)
        response = double("response", code: "200")
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

      # Drive one oMLX `complete` against a stubbed /v1/models (an array of model
      # entries, or a raised error), returning the built request so callers can
      # assert on the forwarded `model` field.
      def run_omlx(client, model:, models_or_error:)
        if models_or_error.is_a?(StandardError)
          allow(client).to receive(:list_models).and_raise(models_or_error)
        else
          allow(client).to receive(:list_models).and_return(models_or_error)
        end

        http = instance_double(Net::HTTP)
        response = double("response", code: "200")
        built = nil
        allow(Net::HTTP).to receive(:start)
          .with("localhost", 8000, open_timeout: 10, read_timeout: 600)
          .and_yield(http)
        allow(http).to receive(:request) { |req, &block| built = req; block.call(response) }
        allow(response).to receive(:read_body)
          .and_yield("data: {\"choices\":[{\"text\":\"ok\"}]}\n")
        client.complete("prompt", model: model)
        built
      end

      it "resolves a selector that exactly equals a bare id in /v1/models (AC #1)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "gemma-4-26b-a4b-it-4bit", models_or_error: ["gemma-4-26b-a4b-it-4bit"])
        expect(request.body).to include('"model":"gemma-4-26b-a4b-it-4bit"')
      end

      it "resolves a short selector to a prefixed id via substring (AC #2)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "gemma-3-4b-it-4bit", models_or_error: ["mlx-community--gemma-3-4b-it-4bit"])
        expect(request.body).to include('"model":"mlx-community--gemma-3-4b-it-4bit"')
      end

      it "passes a full registered id through unchanged (AC #3)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "mlx-community--gemma-3-4b-it-4bit", models_or_error: ["mlx-community--gemma-3-4b-it-4bit"])
        expect(request.body).to include('"model":"mlx-community--gemma-3-4b-it-4bit"')
      end

      it "passes an unknown selector through raw so oMLX 404s with its available list (AC #4)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "nope-xyz", models_or_error: ["mlx-community--gemma-3-4b-it-4bit"])
        expect(request.body).to include('"model":"nope-xyz"')
      end

      it "forwards no model field for an empty selector" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "", models_or_error: ["x"])
        expect(request.body).not_to include('"model"')
      end

      it "falls back to the raw selector when /v1/models is unreachable (AC #9)" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        request = run_omlx(client, model: "gemma-3-4b-it-4bit", models_or_error: RuntimeError.new("server down"))
        expect(request.body).to include('"model":"gemma-3-4b-it-4bit"')
      end

      it "ignores a leading keepalive chunk and still joins text correctly" do
        client = described_class.new(host: "localhost", port: 8000, transport: :omlx)
        http = instance_double(Net::HTTP)
        response = double("response", code: "200")
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
        response = double("response", code: "200")

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
        response = double("response", code: "200")
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
        expect(client.transport.name).to eq(:omlx)
      ensure
        ENV.delete("SAMAGOTCHI_SERVER_TRANSPORT")
      end

      it "resolves uppercase and whitespace-padded values to :omlx" do
        expect(described_class.new(transport: "OMLX").transport.name).to eq(:omlx)
        expect(described_class.new(transport: " omlx ").transport.name).to eq(:omlx)
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
      response = instance_double(Net::HTTPResponse, code: "200", body: '{"data":[{"id":"ggml-org/gemma-4-26b-a4b-it-GGUF:Q4_K_M","status":"loaded"}]}')

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
      client = described_class.new(host: "localhost", port: 8080, sleeper: ->(_seconds) {})
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
        response = instance_double(Net::HTTPResponse, code: "200", body: '{"object":"list","data":[{"id":"mlx-community/Qwen3-14B-Instruct","object":"model","created":1}]}')

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
        response = instance_double(Net::HTTPResponse, code: "200", body: '{"object":"list","data":[{"id":"omlx-community/Qwen3.6","object":"model","created":1}]}')

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

# The raw path against a real (fake) server: statuses and llama.cpp's
# mid-stream error event now fail the turn instead of ending it as "".
describe "server errors" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:client) { described_class.new(host: "127.0.0.1", port: server.port, sleeper: ->(_seconds) {}) }

  after { server.stop }

  it "raises BadRequest for llama.cpp's context overflow, without retrying" do
    server.default("/completion", status: 400, json: FakeProviderServer.fixture("error_400.json"))

    expect { client.complete("prompt") }.to raise_error(Samagotchi::LLM::BadRequest) { |error|
      expect(error).to be_context_overflow
      expect(error.host).to eq("llama.cpp")
    }
    expect(server.requests.size).to eq(1)
  end

  it "retries a 500, then raises ServerError with the attempts" do
    server.default("/completion", status: 500, json: FakeProviderServer.fixture("error_500.hand-written.json"))

    expect { client.complete("prompt") }.to raise_error(Samagotchi::LLM::ServerError) { |error|
      expect(error.attempts).to eq(6)
    }
  end

  it "raises the error llama.cpp sends mid-stream" do
    server.default("/completion", sse: "data: {\"content\":\"Hel\"}\n\nerror: {\"code\":500,\"message\":\"slot unavailable\",\"type\":\"server_error\"}\n\n")
    chunks = []

    expect { client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] }) }
      .to raise_error(Samagotchi::LLM::ServerError, /slot unavailable/)
    expect(chunks).to eq(["Hel"])
    expect(server.requests.size).to eq(1)
  end

  it "raises AuthError when listing models is refused" do
    server.default("/models", status: 401, json: FakeProviderServer.fixture("error_401.hand-written.json"))

    expect { client.list_models }.to raise_error(Samagotchi::LLM::AuthError)
  end
end

  describe "#context_window" do
    # Recorded from llama.cpp started with `-c 128000 --parallel 4`: /props
    # reports the per-slot n_ctx (the same value /slots shows per slot).
    let(:props_body) { File.read(File.expand_path("fixtures/llama_cpp/props.json", __dir__)) }
    let(:client) { described_class.new(host: "localhost", port: 8080, sleeper: ->(_seconds) {}) }
    let(:http) { instance_double(Net::HTTP) }
    let(:requests) { [] }

    def stub_probe(body: props_body, code: "200")
      response = instance_double(Net::HTTPResponse, code: code, body: body)
      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 1, read_timeout: 2)
        .and_yield(http)
      allow(http).to receive(:request) { |req| requests << req.path; response }
    end

    it "reads n_ctx from llama.cpp's /props" do
      stub_probe

      expect(client.context_window(model: "m")).to eq(128_000)
      expect(requests).to eq(["/props"])
    end

    it "probes once per model and serves repeats from the cache" do
      stub_probe

      3.times { client.context_window(model: "m") }
      client.context_window(model: "other")

      expect(requests.size).to eq(2)
    end

    it "caches a server that answers without a window, as nil" do
      stub_probe(code: "404", body: "not found")

      2.times { expect(client.context_window(model: "m")).to be_nil }
      expect(requests.size).to eq(1)
    end

    it "returns nil without retrying or caching when the probe fails" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect(client.context_window(model: "m")).to be_nil
      expect(Net::HTTP).to have_received(:start).once

      stub_probe
      expect(client.context_window(model: "m")).to eq(128_000)
    end

    it "probes again after invalidate_context_window!" do
      stub_probe
      client.context_window(model: "m")

      client.invalidate_context_window!
      client.context_window(model: "m")

      expect(requests.size).to eq(2)
    end

    it "drops the cache when a completion hits a connection error (the server may have restarted)" do
      stub_probe
      client.context_window(model: "m")
      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_raise(Errno::ECONNREFUSED)

      expect { client.complete("prompt") }.to raise_error(described_class::RetryExhausted)
      client.context_window(model: "m")

      expect(requests.size).to eq(2)
    end

    it "does not probe mlx or omlx, which report no window" do
      allow(Net::HTTP).to receive(:start)

      %i[mlx omlx].each do |transport|
        expect(described_class.new(host: "localhost", port: 8000, transport: transport).context_window(model: "m")).to be_nil
      end
      expect(Net::HTTP).not_to have_received(:start)
    end
  end
end
