# frozen_string_literal: true

require "spec_helper"
require "socket"
require "samagotchi/llm/http"
require "samagotchi/cancellation_controller"
require_relative "../support/fake_provider_server"

RSpec.describe Samagotchi::LLM::HTTP do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:sleeps) { [] }
  let(:policy) { described_class::RetryPolicy.new(max: 2, base_delay: 0.5, max_delay: 8.0) }
  let(:http) do
    described_class.new(label: "fake", open_timeout: 2, read_timeout: 5, retry_policy: policy,
                        sleeper: ->(seconds) { sleeps << seconds })
  end
  let(:uri) { URI("#{server.base_url}/chat/completions") }

  after { server.stop }

  def post_request(target = uri)
    Net::HTTP::Post.new(target).tap { |request| request.body = "{}" }
  end

  def closed_port
    socket = TCPServer.new("127.0.0.1", 0)
    socket.addr[1].tap { socket.close }
  end

  describe "#stream_lines" do
    it "yields each streamed line, stripped, as it arrives" do
      server.enqueue("/v1/chat/completions", sse: "data: {\"a\":1}\n\ndata: [DONE]\n\n")
      lines = []

      http.stream_lines(uri, post_request) { |line| lines << line }

      expect(lines).to eq(['data: {"a":1}', "", "data: [DONE]", ""])
    end

    it "retries a dropped connection and reports each retry" do
      # Dropped before any line: nothing was shown, so the request is sent again.
      server.enqueue("/v1/chat/completions", sse: [], drop: true)
      server.enqueue("/v1/chat/completions", sse: "data: 2\n\n")
      retries = []
      errors = []

      lines = []
      http.stream_lines(uri, post_request, on_retry: ->(**event) { retries << event },
                                           on_network_error: ->(error) { errors << error }) { |line| lines << line }

      expect(lines).to eq(["data: 2", ""])
      expect(retries.map { |event| event.slice(:attempt, :max_retries, :next_delay) })
        .to eq([{ attempt: 1, max_retries: 2, next_delay: 0.5 }])
      expect(errors.size).to eq(1)
    end

    it "raises RetryExhausted once the retries run out, after backing off" do
      dead = URI("http://127.0.0.1:#{closed_port}/v1/chat/completions")

      expect { http.stream_lines(dead, post_request(dead)) { nil } }
        .to raise_error(Samagotchi::LLM::RetryExhausted) { |error|
          expect(error.attempts).to eq(3)
          expect(error.last_error).to be_a(Errno::ECONNREFUSED)
          expect(error.message).to start_with("fake request failed after 3 attempts")
        }
      expect(sleeps.sum.round(2)).to eq(1.5)
    end

    it "yields a last line that has no newline" do
      server.enqueue("/v1/chat/completions", sse: ["data: 1\n\ndata: 2"])
      lines = []

      http.stream_lines(uri, post_request) { |line| lines << line }

      expect(lines).to eq(["data: 1", "", "data: 2"])
    end

    it "raises other errors without retrying" do
      server.enqueue("/v1/chat/completions", sse: "data: x\n\n")

      expect { http.stream_lines(uri, post_request) { raise ArgumentError, "bad line" } }
        .to raise_error(ArgumentError, "bad line")
      expect(server.requests.size).to eq(1)
    end

    context "with a cancel" do
      let(:controller) { Samagotchi::CancellationController.new }

      it "does not send a request that is already cancelled" do
        controller.cancel!(:manual)

        expect { http.stream_lines(uri, post_request, cancel_controller: controller) { nil } }
          .to raise_error(Samagotchi::LLM::RequestCancelled) { |error| expect(error.reason).to eq(:manual) }
        expect(server.requests).to be_empty
      end

      # The socket is closed under the reader, which works on any thread
      # (the chat loop used to be unable to cancel on the main thread).
      it "closes the socket of a stream that is still open, on the calling thread" do
        server.enqueue("/v1/chat/completions", sse: ["data: 1\n\n"], hold: true)
        lines = []

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect {
          http.stream_lines(uri, post_request, cancel_controller: controller) do |line|
            lines << line
            Thread.new { controller.cancel!(:ctrl_c) } if line == "data: 1"
          end
        }.to raise_error(Samagotchi::LLM::RequestCancelled) { |error| expect(error.reason).to eq(:ctrl_c) }

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(lines.first).to eq("data: 1")
        expect(server.requests.size).to eq(1)
      end

      it "stops a backoff wait" do
        dead = URI("http://127.0.0.1:#{closed_port}/v1/chat/completions")
        cancelling_sleeper = lambda do |seconds|
          sleeps << seconds
          controller.cancel!(:manual) if sleeps.size == 3
        end
        waiting = described_class.new(label: "fake", open_timeout: 2, read_timeout: 5, retry_policy: policy,
                                      sleeper: cancelling_sleeper)

        expect { waiting.stream_lines(dead, post_request(dead), cancel_controller: controller) { nil } }
          .to raise_error(Samagotchi::LLM::RequestCancelled)
        expect(sleeps.size).to eq(3)
      end

      it "never raises into the caller after the request is over" do
        server.enqueue("/v1/chat/completions", sse: "data: 1\n\n")

        http.stream_lines(uri, post_request, cancel_controller: controller) { nil }

        expect { controller.cancel!(:manual); sleep 0.05 }.not_to raise_error
      end
    end
  end

  describe "HTTP status errors" do
    def stream!(target = uri)
      http.stream_lines(target, post_request(target)) { nil }
    end

    {
      400 => [Samagotchi::LLM::BadRequest, false, :bad_request],
      401 => [Samagotchi::LLM::AuthError, false, :auth],
      403 => [Samagotchi::LLM::AuthError, false, :auth],
      404 => [Samagotchi::LLM::BadRequest, false, :bad_request],
      422 => [Samagotchi::LLM::BadRequest, false, :bad_request],
      429 => [Samagotchi::LLM::RateLimited, true, :rate_limited],
      500 => [Samagotchi::LLM::ServerError, true, :server],
      501 => [Samagotchi::LLM::ServerError, false, :server],
      503 => [Samagotchi::LLM::ServerError, true, :server]
    }.each do |status, (klass, retryable, kind)|
      it "maps HTTP #{status} to #{klass.name.split("::").last}#{retryable ? ", retried" : ""}" do
        server.default("/v1/chat/completions", status: status, json: { error: { message: "nope #{status}" } })

        expect { stream! }.to raise_error(klass) { |error|
          expect(error.status).to eq(status)
          expect(error.kind).to eq(kind)
          expect(error.retryable?).to be(retryable)
          expect(error.host).to eq("fake")
          expect(error.message).to eq("fake: HTTP #{status}: nope #{status}")
          expect(error.attempts).to eq(retryable ? 3 : 1)
        }
        expect(server.requests.size).to eq(retryable ? 3 : 1)
        expect(klass.ancestors).to include(Samagotchi::LLM::ProviderError)
      end
    end

    it "waits what Retry-After asks, then succeeds" do
      server.enqueue("/v1/chat/completions", status: 429, json: FakeProviderServer.fixture("error_429.hand-written.json"),
                                             headers: { "Retry-After" => "2" })
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")
      lines = []

      http.stream_lines(uri, post_request) { |line| lines << line }

      expect(lines.first).to eq("data: ok")
      expect(sleeps.sum.round(2)).to eq(2.0)
    end

    it "does not wait out a Retry-After longer than a minute" do
      server.default("/v1/chat/completions", status: 429, json: { error: { message: "slow down" } },
                                             headers: { "Retry-After" => "600" })

      expect { stream! }.to raise_error(Samagotchi::LLM::RateLimited) { |error| expect(error.retry_after).to eq(600.0) }
      expect(sleeps).to be_empty
      expect(server.requests.size).to eq(1)
    end

    it "maps llama.cpp's context overflow 400 to a BadRequest it never retries" do
      server.default("/v1/chat/completions", status: 400, json: FakeProviderServer.fixture("error_400.json"))

      expect { stream! }.to raise_error(Samagotchi::LLM::BadRequest) { |error|
        expect(error).to be_context_overflow
        expect(error.message).to include("exceeds the available context size")
      }
      expect(server.requests.size).to eq(1)
    end

    it "treats a context overflow reported as a 500 as a BadRequest too" do
      server.default("/v1/chat/completions", status: 500,
                                             json: { error: { code: 500, message: "the request exceeds the available context size, try increasing it" } })

      expect { stream! }.to raise_error(Samagotchi::LLM::BadRequest)
      expect(server.requests.size).to eq(1)
    end

    it "does not retry a stream whose lines the caller showed; the drop fails as a connection error" do
      server.default("/v1/chat/completions", sse: ["data: 1\n\n"], drop: true)
      lines = []

      expect {
        http.stream_lines(uri, post_request) do |line, shown|
          lines << line
          shown.call
        end
      }
        .to raise_error(Samagotchi::LLM::RetryExhausted) { |error|
          expect(error).to be_a(Samagotchi::LLM::ConnectionError)
          expect(error.attempts).to eq(1)
          expect(error.kind).to eq(:connection)
        }
      expect(lines.first).to eq("data: 1")
      expect(server.requests.size).to eq(1)
    end

    it "retries a drop when the caller showed none of the lines yet" do
      server.enqueue("/v1/chat/completions", sse: [": PROCESSING\n\n", "data: role only\n\n"], drop: true)
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")
      lines = []

      http.stream_lines(uri, post_request) { |line| lines << line }

      expect(lines.reject(&:empty?).last).to eq("data: ok")
      expect(server.requests.size).to eq(2)
    end

    it "retries an error line raised before anything was shown, by its kind" do
      server.enqueue("/v1/chat/completions", sse: "data: {\"choices\":[],\"error\":{\"code\":429,\"message\":\"busy\"}}\n\n")
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")
      retries = []

      http.stream_lines(uri, post_request, on_retry: ->(**event) { retries << event }) do |line, shown|
        error = described_class.sse_error(line, host: "fake")
        raise error if error

        shown.call unless line.empty?
      end

      expect(retries.map { |event| event[:error_class] }).to eq(["Samagotchi::LLM::RateLimited"])
      expect(server.requests.size).to eq(2)
    end

    it "does not retry an error line after the caller showed a line" do
      server.default("/v1/chat/completions", sse: "data: hi\n\ndata: {\"error\":{\"code\":503,\"message\":\"gone\"}}\n\n")

      expect {
        http.stream_lines(uri, post_request) do |line, shown|
          error = described_class.sse_error(line, host: "fake")
          raise error if error

          shown.call unless line.empty?
        end
      }.to raise_error(Samagotchi::LLM::ServerError, /gone/) { |error| expect(error.attempts).to eq(1) }
      expect(server.requests.size).to eq(1)
    end

    it "stops a backoff wait after a 503" do
      controller = Samagotchi::CancellationController.new
      server.default("/v1/chat/completions", status: 503, json: { error: { message: "busy" } })
      cancelling = described_class.new(label: "fake", open_timeout: 2, read_timeout: 5, retry_policy: policy,
                                       sleeper: ->(_seconds) { controller.cancel!(:ctrl_c) })

      expect { cancelling.stream_lines(uri, post_request, cancel_controller: controller) { nil } }
        .to raise_error(Samagotchi::LLM::RequestCancelled)
      expect(server.requests.size).to eq(1)
    end
  end

  describe "SSE error events" do
    it "maps llama.cpp's mid-stream error line to a ProviderError" do
      error = described_class.sse_error('error: {"code":500,"message":"slot unavailable","type":"server_error"}', host: "box")

      expect(error).to be_a(Samagotchi::LLM::ServerError)
      expect(error.message).to eq("box: HTTP 500: slot unavailable")
    end

    it "reads an OpenAI-style error object in a data line" do
      error = described_class.sse_error('data: {"error":{"message":"overloaded","type":"server_error"}}', host: "box")

      expect(error).to be_a(Samagotchi::LLM::ServerError)
    end

    it "ignores ordinary lines" do
      expect(described_class.sse_error('data: {"choices":[]}', host: "box")).to be_nil
      expect(described_class.sse_error("", host: "box")).to be_nil
    end
  end

  describe "User-Agent" do
    it "names chi and its version on streamed and fetched requests" do
      server.enqueue("/v1/chat/completions", sse: "data: 1\n\n")
      server.enqueue("/v1/models", json: { data: [] })

      http.stream_lines(uri, post_request) { nil }
      http.fetch(URI("#{server.base_url}/models"), Net::HTTP::Get.new(URI("#{server.base_url}/models")))

      expect(server.requests.map { |request| request.header("User-Agent") })
        .to eq(["chi/#{Samagotchi::VERSION}"] * 2)
    end
  end

  describe "#fetch" do
    it "returns the response with its body" do
      server.enqueue("/v1/models", json: { data: [] })

      response = http.fetch(URI("#{server.base_url}/models"), Net::HTTP::Get.new(URI("#{server.base_url}/models")))

      expect(response.code).to eq("200")
      expect(response.body).to eq('{"data":[]}')
    end

    it "raises the mapped error for a failed status, or returns it with check_status: false" do
  models = URI("#{server.base_url}/models")
  server.default("/v1/models", status: 401, json: { error: { message: "bad key" } })

  expect { http.fetch(models, Net::HTTP::Get.new(models)) }.to raise_error(Samagotchi::LLM::AuthError)
  expect(http.fetch(models, Net::HTTP::Get.new(models), check_status: false).code).to eq("401")
end

it "makes one attempt with retries: false" do
      dead = URI("http://127.0.0.1:#{closed_port}/props")

      expect { http.fetch(dead, Net::HTTP::Get.new(dead), retries: false) }.to raise_error(Errno::ECONNREFUSED)
      expect(sleeps).to be_empty
    end
  end

  it "uses TLS for an https URL" do
    secure = URI("https://api.example.test/v1/models")
    allow(Net::HTTP).to receive(:start)
      .with("api.example.test", 443, open_timeout: 2, read_timeout: 5, use_ssl: true)
      .and_return(:response)

    expect(http.fetch(secure, Net::HTTP::Get.new(secure))).to eq(:response)
  end

  describe described_class::RetryPolicy do
    it "backs off exponentially up to max_delay, then gives up" do
      policy = described_class.new(max: 5, base_delay: 0.5, max_delay: 2.0)

      expect((1..6).map { |attempt| policy.delay_for(attempt) }).to eq([0.5, 1.0, 2.0, 2.0, 2.0, nil])
    end
  end
end
