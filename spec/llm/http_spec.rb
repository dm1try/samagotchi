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
      server.enqueue("/v1/chat/completions", sse: ["data: 1\n\n"], drop: true)
      server.enqueue("/v1/chat/completions", sse: "data: 2\n\n")
      retries = []
      errors = []

      lines = []
      http.stream_lines(uri, post_request, on_retry: ->(**event) { retries << event },
                                           on_network_error: ->(error) { errors << error }) { |line| lines << line }

      expect(lines).to eq(["data: 1", "", "data: 2", ""])
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

  describe "#fetch" do
    it "returns the response with its body" do
      server.enqueue("/v1/models", json: { data: [] })

      response = http.fetch(URI("#{server.base_url}/models"), Net::HTTP::Get.new(URI("#{server.base_url}/models")))

      expect(response.code).to eq("200")
      expect(response.body).to eq('{"data":[]}')
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
