# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/errors"

RSpec.describe Samagotchi::LLM::ProviderError do
  def from(status, message, **options)
    Samagotchi::LLM::ProviderErrors.from_response(status: status, body: JSON.generate(error: { message: message }), host: "fw", **options)
  end

  describe "#summary: one line per kind for the UIs" do
    it "names the variable for a missing key, and the server's words for a refused one" do
      missing = Samagotchi::LLM::AuthError.new("fw: set FW_KEY (the API key for host fw)", host: "fw")

      expect(missing.summary).to eq("auth failed for host fw: set FW_KEY (the API key for host fw)")
      expect(from(401, "Invalid API key").summary).to eq("auth failed for host fw: HTTP 401: Invalid API key")
    end

    it "gives a rate limit's reason and how long it asks to wait" do
      expect(from(429, "slow down", retry_after: "20").summary).to eq("rate limited by host fw: HTTP 429: slow down; retry after 20s")
      expect(from(429, "slow down").summary).to eq("rate limited by host fw: HTTP 429: slow down")
    end

    it "reads the upstream reason and provider from error.metadata (OpenRouter's recorded 429)" do
      error = Samagotchi::LLM::ProviderErrors.from_response(
        status: 429, body: File.read(File.expand_path("../fixtures/providers/openai/openrouter_error_429.json", __dir__)),
        host: "openrouter", retry_after: "5"
      )

      expect(error.summary).to eq(
        "rate limited by host openrouter: HTTP 429: Provider returned error (Decart): z-ai/glm-5.2:free is temporarily " \
        "rate-limited upstream. Please retry shortly, or add your own key to accumulate your rate limits: " \
        "https://openrouter.ai/settings/integrations; retry after 5s"
      )
    end

    it "reads a metadata.raw that is itself a JSON error body, and keeps a plain message as is" do
      body = JSON.generate(error: { message: "Provider returned error",
                                    metadata: { raw: JSON.generate(error: { message: "model overloaded" }) } })

      expect(Samagotchi::LLM::ProviderErrors.error_message(body)).to eq("Provider returned error: model overloaded")
      expect(Samagotchi::LLM::ProviderErrors.error_message(JSON.generate(error: { message: "plain", metadata: {} })))
        .to eq("plain")
    end

    it "carries the reason of an in-stream error event too" do
      line = 'data: {"choices":[],"error":{"code":429,"message":"Provider returned error",' \
             '"metadata":{"raw":"shared pool busy","provider_name":"Up"}}}'

      expect(Samagotchi::LLM::ProviderErrors.from_sse_line(line, host: "or").summary)
        .to eq("rate limited by host or: HTTP 429: Provider returned error (Up): shared pool busy")
    end

    it "reports connection failures with the attempts" do
      error = Samagotchi::LLM::RetryExhausted.new(attempts: 4, last_error: Errno::ECONNREFUSED.new, label: "main")

      expect(error.summary).to eq("network error after 4 attempts (host main: Errno::ECONNREFUSED)")
    end

    it "tells a context overflow from other bad requests" do
      overflow = Samagotchi::LLM::ProviderErrors.from_response(
        status: 400, body: File.read(File.expand_path("../fixtures/providers/openai/error_400.json", __dir__)), host: "main"
      )

      expect(overflow.summary).to start_with("the conversation is too long for host main's context window: HTTP 400: request (140010 tokens)")
      expect(from(404, "model not found").summary).to eq("host fw rejected the request: HTTP 404: model not found")
    end

    it "covers server and protocol errors" do
      expect(from(503, "busy").summary).to eq("server error from host fw: HTTP 503: busy")
      expect(Samagotchi::LLM::ProtocolError.new("fw: malformed stream chunk: x", host: "fw").summary)
        .to eq("unexpected response from host fw: malformed stream chunk: x")
    end
  end
end
