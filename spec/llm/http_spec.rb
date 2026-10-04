# frozen_string_literal: true

require "spec_helper"
require "socket"
require "samagotchi/llm/http"
require "samagotchi/cancellation_controller"
require "fileutils"
require "tmpdir"
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
    Net::HTTP::Post.new(target, "Content-Type" => "application/json").tap { |request| request.body = "{}" }
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
      expect(retries.map { |event| event.slice(:attempt, :max_retries, :next_delay, :status) })
        .to eq([{ attempt: 1, max_retries: 2, next_delay: 0.5, status: nil }])
      expect(errors.size).to eq(1)
    end

    it "raises RetryExhausted once the retries run out, after backing off" do
      3.times { server.enqueue("/v1/chat/completions", sse: [], drop: true) }

      expect { http.stream_lines(uri, post_request) { nil } }
        .to raise_error(Samagotchi::LLM::RetryExhausted) { |error|
          expect(error.attempts).to eq(3)
          expect(error.last_error).to be_a(EOFError)
          expect(error.message).to start_with("fake request failed after 3 attempts")
        }
      expect(sleeps.sum.round(2)).to eq(1.5)
    end

    it "fails a refused connection at once, naming the host and its address" do
      port = closed_port
      dead = URI("http://127.0.0.1:#{port}/v1/chat/completions")
      real = described_class.new(label: "main", open_timeout: 2, read_timeout: 5, retry_policy: policy)
      errors = []

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { real.stream_lines(dead, post_request(dead), on_network_error: ->(error) { errors << error }) { nil } }
        .to raise_error(Samagotchi::LLM::ConnectionRefused) { |error|
          expect(error.attempts).to eq(1)
          expect(error).not_to be_retryable
          expect(error.summary)
            .to eq("can't reach host main at 127.0.0.1:#{port} (connection refused) — is the server running?")
        }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(errors.map(&:class)).to eq([Errno::ECONNREFUSED])
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

    context "with a first-token limit" do
      let(:limited) do
        described_class.new(label: "fake", open_timeout: 2, read_timeout: 5, retry_policy: policy,
                            sleeper: ->(seconds) { sleeps << seconds }, first_token_timeout: 0.3)
      end
      let(:keep_alives) { Array.new(40) { ": OPENROUTER PROCESSING\n\n" } }

      # OpenRouter keeps a queued request alive with SSE comments, which
      # reset the read timeout: only a wall-clock limit ends the wait.
      it "fails a stream that sends only keep-alives, once, without a retry" do
        server.enqueue("/v1/chat/completions", sse: keep_alives, delay: 0.05, hold: true)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect { limited.stream_lines(uri, post_request) { nil } }
          .to raise_error(Samagotchi::LLM::FirstTokenTimeout) { |error|
            expect(error.kind).to eq(:first_token_timeout)
            expect(error).not_to be_retryable
            expect(error.summary).to eq("no answer from host fake within 0.3s (first_token_timeout); " \
                                        "try again later or pick another model (/model)")
          }
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1.5
        expect(server.requests.size).to eq(1)
        expect(sleeps).to be_empty
      end

      it "stops watching once the caller showed something" do
        server.enqueue("/v1/chat/completions", sse: ["data: 1\n\n", "data: 2\n\n", "data: 3\n\n"], delay: 0.25)
        lines = []

        limited.stream_lines(uri, post_request) do |line, shown|
          lines << line
          shown.call if line == "data: 1"
        end

        expect(lines.reject(&:empty?)).to eq(["data: 1", "data: 2", "data: 3"])
      end

      it "is off without a limit" do
        server.enqueue("/v1/chat/completions", sse: [": PROCESSING\n\n"] * 6 + ["data: ok\n\n"], delay: 0.1)
        lines = []

        http.stream_lines(uri, post_request) { |line| lines << line }

        expect(lines.reject(&:empty?).last).to eq("data: ok")
      end

      it "lets a cancel win over the limit" do
        controller = Samagotchi::CancellationController.new
        server.enqueue("/v1/chat/completions", sse: keep_alives, delay: 0.05, hold: true)

        expect do
          limited.stream_lines(uri, post_request, cancel_controller: controller) do |_line|
            controller.cancel!(:ctrl_c)
          end
        end.to raise_error(Samagotchi::LLM::RequestCancelled)
      end
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
        expect do
          http.stream_lines(uri, post_request, cancel_controller: controller) do |line|
            lines << line
            Thread.new { controller.cancel!(:ctrl_c) } if line == "data: 1"
          end
        end.to raise_error(Samagotchi::LLM::RequestCancelled) { |error| expect(error.reason).to eq(:ctrl_c) }

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
        expect(lines.first).to eq("data: 1")
        expect(server.requests.size).to eq(1)
      end

      it "stops a backoff wait" do
        server.default("/v1/chat/completions", sse: [], drop: true)
        dead = uri
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
      402 => [Samagotchi::LLM::OutOfCredits, false, :credits],
      "402 in-flight requests" => [Samagotchi::LLM::CreditsHeld, true, :credits_held],
      401 => [Samagotchi::LLM::AuthError, false, :auth],
      403 => [Samagotchi::LLM::AuthError, false, :auth],
      404 => [Samagotchi::LLM::BadRequest, false, :bad_request],
      422 => [Samagotchi::LLM::BadRequest, false, :bad_request],
      429 => [Samagotchi::LLM::RateLimited, true, :rate_limited],
      500 => [Samagotchi::LLM::ServerError, true, :server],
      501 => [Samagotchi::LLM::ServerError, false, :server],
      503 => [Samagotchi::LLM::ServerError, true, :server]
    }.each do |key, (klass, retryable, kind)|
      it "maps HTTP #{key} to #{klass.name.split("::").last}#{", retried" if retryable}" do
        status = key.to_s.to_i
        message = "nope #{key}"
        server.default("/v1/chat/completions", status: status, json: { error: { message: message } })

        expect { stream! }.to raise_error(klass) { |error|
          expect(error.status).to eq(status)
          expect(error.kind).to eq(kind)
          expect(error.retryable?).to be(retryable)
          expect(error.host).to eq("fake")
          expect(error.message).to eq("fake: HTTP #{status}: #{message}")
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

    it "waits 20 s after a 402 about credits held by in-flight requests, then succeeds" do
      server.enqueue("/v1/chat/completions", status: 402,
                                             json: { error: { code: 402, message: "would exceed your available credits given your current in-flight requests" } })
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")
      lines = []

      http.stream_lines(uri, post_request) { |line| lines << line }

      expect(lines.first).to eq("data: ok")
      expect(sleeps).to eq([20.0])
      expect(server.requests.size).to eq(2)
    end

    it "fails at once on a 402 out of credits" do
      server.default("/v1/chat/completions", status: 402, json: { error: { code: 402, message: "Insufficient credits" } })

      expect { stream! }.to raise_error(Samagotchi::LLM::OutOfCredits) { |error| expect(error.attempts).to eq(1) }
      expect(sleeps).to be_empty
      expect(server.requests.size).to eq(1)
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

      expect do
        http.stream_lines(uri, post_request) do |line, shown|
          lines << line
          shown.call
        end
      end
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

      expect(retries.map { |event| event.slice(:error_class, :status) }).to eq([{ error_class: "Samagotchi::LLM::RateLimited", status: 429 }])
      expect(server.requests.size).to eq(2)
    end

    it "retries an in-flight 402 error line raised before anything was shown" do
      server.enqueue("/v1/chat/completions",
                     sse: "data: {\"error\":{\"code\":402,\"message\":\"credits given your current in-flight requests\"}}\n\n")
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")
      lines = []

      http.stream_lines(uri, post_request) do |line, shown|
        error = described_class.sse_error(line, host: "fake")
        raise error if error

        lines << line
        shown.call unless line.empty?
      end

      expect(lines.first).to eq("data: ok")
      expect(sleeps).to eq([20.0])
      expect(server.requests.size).to eq(2)
    end

    it "does not retry an error line after the caller showed a line" do
      server.default("/v1/chat/completions", sse: "data: hi\n\ndata: {\"error\":{\"code\":503,\"message\":\"gone\"}}\n\n")

      expect do
        http.stream_lines(uri, post_request) do |line, shown|
          error = described_class.sse_error(line, host: "fake")
          raise error if error

          shown.call unless line.empty?
        end
      end.to raise_error(Samagotchi::LLM::ServerError, /gone/) { |error| expect(error.attempts).to eq(1) }
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

  describe "log lines (tag http)" do
    let(:log_dir) { Dir.mktmpdir("samagotchi-log") }
    let(:log_path) { File.join(log_dir, "chi.log") }
    before { Samagotchi::Log.configure(path: log_path, level: :debug) }
    after { FileUtils.remove_entry(log_dir) }

    def http_records
      return [] unless File.exist?(log_path)

      File.open(log_path) { |io| Samagotchi::LogLine.each_record(io).select { |r| r.tag == "http" } }
    end

    let(:chat) { { model: "qwen", purpose: "chat" } }

    it "writes one INFO line per stream: host, model, status, time to first token, total; never the body" do
      server.enqueue("/v1/chat/completions", sse: "data: {\"secret\":1}\n\n")
      request = post_request
      request["Authorization"] = "Bearer sk-secret"

      http.stream_lines(uri, request, log_fields: chat) { |_line, shown| shown.call }

      expect(http_records.size).to eq(1)
      record = http_records.first
      expect(record.to_h).to include(level: "INFO", event: "stream")
      expect(record.fields).to include("host" => "fake", "method" => "POST", "url" => "#{server.base_url}/chat/completions",
                                       "model" => "qwen", "purpose" => "chat", "status" => "200")
      expect(Integer(record.fields["ttft_ms"])).to be <= Integer(record.fields["ms"])
      expect(File.read(log_path)).not_to include("secret")
    end

    it "writes a WARN per retry (a 429 here), then the stream with its attempts" do
      server.enqueue("/v1/chat/completions", status: 429, json: { error: { message: "slow down" } }, headers: { "Retry-After" => "1" })
      server.enqueue("/v1/chat/completions", sse: "data: ok\n\n")

      http.stream_lines(uri, post_request, log_fields: chat) { |_line, shown| shown.call }

      stream = http_records.last
      # The answering attempt's time to first token, not the backoff before it.
      expect(Integer(stream.fields["ttft_ms"])).to be <= Integer(stream.fields["ms"])
      expect(http_records.map { |r| [r.level, r.event, r.fields.slice("status", "attempt", "delay_s", "attempts")] }).to eq([
        ["WARN", "retry", { "status" => "429", "attempt" => "1", "delay_s" => "1.0" }],
        ["INFO", "stream", { "status" => "200", "attempts" => "2" }]
      ])
    end

    it "writes a WARN for a network retry too, and an ERROR when they run out" do
      3.times { server.enqueue("/v1/chat/completions", sse: [], drop: true) }

      expect { http.stream_lines(uri, post_request, log_fields: chat) { nil } }
        .to raise_error(Samagotchi::LLM::RetryExhausted)

      expect(http_records.map { |r| [r.level, r.event] }).to eq([%w[WARN retry], %w[WARN retry], %w[ERROR retry_exhausted]])
      expect(http_records.last.fields).to include("attempts" => "3", "error" => "Samagotchi::LLM::RetryExhausted")
    end

    it "writes an ERROR for a Retry-After too long to wait out" do
      server.default("/v1/chat/completions", status: 429, json: { error: { message: "slow down" } }, headers: { "Retry-After" => "600" })

      expect { http.stream_lines(uri, post_request, log_fields: chat) { nil } }.to raise_error(Samagotchi::LLM::RateLimited)

      expect(http_records.map { |r| [r.level, r.event, r.fields["status"]] }).to eq([%w[ERROR failed 429]])
    end

    it "writes an ERROR for a first-token timeout" do
      limited = described_class.new(label: "fake", open_timeout: 2, read_timeout: 5, retry_policy: policy,
                                    sleeper: ->(seconds) { sleeps << seconds }, first_token_timeout: 0.2)
      server.enqueue("/v1/chat/completions", sse: Array.new(20) { ": PROCESSING\n\n" }, delay: 0.05, hold: true)

      expect { limited.stream_lines(uri, post_request, log_fields: chat) { nil } }.to raise_error(Samagotchi::LLM::FirstTokenTimeout)
      server.release

      expect(http_records.map { |r| [r.level, r.event] }).to eq([%w[ERROR first_token_timeout]])
    end

    it "writes a cancelled request as INFO" do
      controller = Samagotchi::CancellationController.new
      controller.cancel!(:ctrl_c)

      expect { http.stream_lines(uri, post_request, cancel_controller: controller, log_fields: chat) { nil } }
        .to raise_error(Samagotchi::LLM::RequestCancelled)

      expect(http_records.map { |r| [r.level, r.event, r.fields["reason"]] }).to eq([%w[INFO cancelled ctrl_c]])
    end

    it "writes a cancelled probe as DEBUG: a Stop is no probe failure" do
      controller = Samagotchi::CancellationController.new
      controller.cancel!(:user)
      props = URI("#{server.base_url}/props")

      expect { http.fetch(props, Net::HTTP::Get.new(props), retries: false, cancel_controller: controller, log_fields: { purpose: "probe" }) }
        .to raise_error(Samagotchi::LLM::RequestCancelled)

      expect(http_records.map { |r| [r.level, r.event, r.fields["reason"]] }).to eq([%w[DEBUG cancelled user]])
    end

    it "keeps probes and model lists at DEBUG, failures included" do
      server.enqueue("/v1/props", status: 404, json: { error: "no" })
      server.enqueue("/v1/models", json: { data: [] })

      http.fetch(URI("#{server.base_url}/props?model=q"), Net::HTTP::Get.new(URI("#{server.base_url}/props")),
                 retries: false, check_status: false, log_fields: { purpose: "probe" })
      http.fetch(URI("#{server.base_url}/models"), Net::HTTP::Get.new(URI("#{server.base_url}/models")),
                 log_fields: { purpose: "models" })
      expect do
        http.fetch(URI("http://127.0.0.1:#{closed_port}/props"), Net::HTTP::Get.new(URI("http://127.0.0.1:1/props")),
                   retries: false, log_fields: { purpose: "probe" })
      end.to raise_error(Errno::ECONNREFUSED)

      expect(http_records.map { |r| [r.level, r.event, r.fields["status"]] })
        .to eq([%w[DEBUG fetch 404], %w[DEBUG fetch 200], ["DEBUG", "failed", nil]])
      expect(http_records.first.fields["url"]).to eq("#{server.base_url}/props")
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

    context "with retries: false and a cancel" do
      let(:controller) { Samagotchi::CancellationController.new }
      # Accepts and never answers.
      let(:hung) { TCPServer.new("127.0.0.1", 0) }
      let(:hung_uri) { URI("http://127.0.0.1:#{hung.addr[1]}/props") }
      let(:accepted) { Queue.new }

      before do
        @acceptor = Thread.new do
          loop { accepted << hung.accept }
        rescue IOError, Errno::EBADF
          nil
        end
      end

      after do
        @acceptor.kill
        hung.close
        accepted.size.times { accepted.pop.close }
      end

      it "closes the socket of a request waiting for its answer" do
        Thread.new do
          accepted.pop.tap { |socket| accepted << socket }
          sleep 0.05
          controller.cancel!(:user)
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect { http.fetch(hung_uri, Net::HTTP::Get.new(hung_uri), retries: false, cancel_controller: controller) }
          .to raise_error(Samagotchi::LLM::RequestCancelled) { |error| expect(error.reason).to eq(:user) }
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      end

      it "does not send a request that is already cancelled" do
        controller.cancel!(:user)

        expect { http.fetch(hung_uri, Net::HTTP::Get.new(hung_uri), retries: false, cancel_controller: controller) }
          .to raise_error(Samagotchi::LLM::RequestCancelled)
        sleep 0.05
        expect(accepted).to be_empty
      end

      it "never raises into the caller after the request is over" do
        server.enqueue("/v1/models", json: { data: [] })
        models = URI("#{server.base_url}/models")

        http.fetch(models, Net::HTTP::Get.new(models), retries: false, cancel_controller: controller)

        expect { controller.cancel!(:user); sleep 0.05 }.not_to raise_error
      end
    end
  end

  it "uses TLS for an https URL" do
    secure = URI("https://api.example.test/v1/models")
    allow(Net::HTTP).to receive(:start)
      .with("api.example.test", 443, open_timeout: 2, read_timeout: 5, max_retries: 0, use_ssl: true)
      .and_return(:response)

    expect(http.fetch(secure, Net::HTTP::Get.new(secure))).to eq(:response)
  end

  describe "Net::HTTP's own retries" do
    # Net::HTTP retries an idempotent request once by itself when the
    # connection drops before an answer (max_retries: 1). chi's RetryPolicy
    # owns retries (and logs each one), so every connection it opens must
    # turn Net::HTTP's silent one off.
    it "turns Net::HTTP's hidden retry off on a streamed request and a GET" do
      server.enqueue("/v1/chat/completions", sse: "data: 1\n\n")
      server.enqueue("/v1/props", json: { ok: true })
      props = URI("#{server.base_url}/props")
      allow(Net::HTTP).to receive(:start).and_call_original

      http.stream_lines(uri, post_request) { nil }
      http.fetch(props, Net::HTTP::Get.new(props), retries: false, check_status: false)

      expect(Net::HTTP).to have_received(:start).twice do |_host, _port, **options|
        expect(options[:max_retries]).to eq(0)
      end
    end

    it "turns it off on a GET that chi retries itself" do
      server.enqueue("/v1/models", json: { data: [] })
      models = URI("#{server.base_url}/models")
      allow(Net::HTTP).to receive(:start).and_call_original

      http.fetch(models, Net::HTTP::Get.new(models))

      expect(Net::HTTP).to have_received(:start).with(anything, anything, hash_including(max_retries: 0))
    end
  end

  describe described_class::RetryPolicy do
    it "backs off exponentially up to max_delay, then gives up" do
      policy = described_class.new(max: 5, base_delay: 0.5, max_delay: 2.0)

      expect((1..6).map { |attempt| policy.delay_for(attempt) }).to eq([0.5, 1.0, 2.0, 2.0, 2.0, nil])
    end
  end
end
