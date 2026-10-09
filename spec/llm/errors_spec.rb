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

    it "retries a 402 about credits held by in-flight requests, waiting 20 s or what Retry-After asks" do
      message = "This request would exceed your available credits given your current in-flight requests. " \
                "Retry after in-flight requests settle, or add credits."
      held = from(402, message)

      expect(held).to be_a(Samagotchi::LLM::CreditsHeld).and be_a(Samagotchi::LLM::RateLimited)
      expect(held).to be_retryable
      expect(held.kind).to eq(:credits_held)
      expect(held.retry_after).to eq(20.0)
      expect(held.summary).to eq("credits on host fw are held by in-flight requests (retry after 20s)")
      expect(from(402, message, retry_after: "7").retry_after).to eq(7.0)
    end

    it "names any other 402 as out of credits, never retried" do
      error = from(402, "Insufficient credits. Add more using https://openrouter.ai/settings/credits")

      expect(error).to be_a(Samagotchi::LLM::OutOfCredits)
      expect(error).not_to be_a(Samagotchi::LLM::BadRequest)
      expect(error).not_to be_retryable
      expect(error.kind).to eq(:credits)
      expect(error.summary).to eq("out of credits on host fw: HTTP 402: Insufficient credits. Add more using " \
                                  "https://openrouter.ai/settings/credits; add credits, then send again")
      expect(from(400, "in-flight requests")).to be_a(Samagotchi::LLM::BadRequest)
    end

    it "fails fast on a 402 whose metadata.reason is weight_exceeds_budget, even worded like the in-flight one" do
      body = JSON.generate(error: { code: 402, metadata: { reason: "weight_exceeds_budget" },
                                    message: "This request would exceed your available credits given your current " \
                                             "in-flight requests. Retry after in-flight requests settle, or add credits." })
      error = Samagotchi::LLM::ProviderErrors.from_response(status: 402, body: body, host: "fw", retry_after: "5")

      expect(error).to be_a(Samagotchi::LLM::OverBudget).and be_a(Samagotchi::LLM::OutOfCredits)
      expect(error).not_to be_a(Samagotchi::LLM::CreditsHeld)
      expect(error).not_to be_retryable
      expect(error.kind).to eq(:credits)
      expect(error.summary).to start_with("request too large for the credit budget on host fw: HTTP 402: This request")
      expect(error.summary).to end_with("; lower max_tokens (default.max_tokens) or raise the key's credit limit")

      line = "data: #{JSON.generate(error: { code: 402, message: "x", metadata: { reason: "weight_exceeds_budget" } })}"
      expect(Samagotchi::LLM::ProviderErrors.from_sse_line(line, host: "or")).to be_a(Samagotchi::LLM::OverBudget)
      other = JSON.generate(error: { code: 402, message: "in-flight requests", metadata: { reason: "something_else" } })
      expect(Samagotchi::LLM::ProviderErrors.from_response(status: 402, body: other, host: "fw"))
        .to be_a(Samagotchi::LLM::CreditsHeld)
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

    it "adds a hint when the model has no tool-capable endpoint (OpenRouter's recorded 404)" do
      error = Samagotchi::LLM::ProviderErrors.from_response(
        status: 404, body: File.read(File.expand_path("../fixtures/providers/openai/openrouter_error_404_no_tools.json", __dir__)),
        host: "openrouter"
      )

      expect(error).to be_a(Samagotchi::LLM::BadRequest)
      expect(error).to be_tools_unsupported
      # OpenRouter's own advice ("Try disabling "execute"…", a routing docs
      # link) is for its web UI and doesn't apply to chi: only its first
      # sentence stays, then chi's hint.
      expect(error.summary).to eq(
        "host openrouter rejected the request: HTTP 404: No endpoints found that support tool use; " \
        "this model can't use tools, and chi needs them: pick another model (/model) or host"
      )
      expect(error.message).to include("Try disabling")
    end

    it "recognises other servers' words for a model without tools, and nothing else" do
      tools_error = lambda do |status, message|
        Samagotchi::LLM::ProviderErrors.from_response(status: status, body: JSON.generate(error: { message: message }),
                                                      host: "h")
      end

      expect(tools_error.call(400, "registry.ollama.ai/library/gemma:2b does not support tools")).to be_tools_unsupported
      expect(tools_error.call(400, '"auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set'))
        .to be_tools_unsupported
      expect(tools_error.call(400, "gemma:2b does not support tools").summary)
        .to eq("host h rejected the request: HTTP 400: gemma:2b does not support tools; #{Samagotchi::LLM::BadRequest::TOOLS_HINT}")
      expect(tools_error.call(404, "No endpoints found for foo/bar:free.")).not_to be_tools_unsupported
      expect(tools_error.call(404, "No endpoints found for foo/bar:free.").summary).not_to include("can't use tools")
    end

    it "marks a 400 about reasoning or thinking as refused thinking fields, and nothing else" do
      error = lambda do |status, message|
        Samagotchi::LLM::ProviderErrors.from_response(status: status, body: JSON.generate(error: { message: message }),
                                                      host: "h")
      end

      expect(error.call(400, "Reasoning is mandatory for this endpoint and cannot be disabled.")).to be_reasoning_refused
      expect(error.call(400, "Unrecognized request argument: enable_thinking")).to be_reasoning_refused
      expect(error.call(400, "invalid temperature")).not_to be_reasoning_refused
      expect(error.call(400, "gemma:2b does not support tools")).not_to be_reasoning_refused
      expect(error.call(500, "reasoning crashed")).not_to be_a(Samagotchi::LLM::BadRequest)
    end

    it "reads a metadata.raw that is itself a JSON error body, and keeps a plain message as is" do
      body = JSON.generate(error: { message: "Provider returned error",
                                    metadata: { raw: JSON.generate(error: { message: "model overloaded" }) } })

      expect(Samagotchi::LLM::ProviderErrors.error_message(body)).to eq("Provider returned error: model overloaded")
      expect(Samagotchi::LLM::ProviderErrors.error_message(JSON.generate(error: { message: "plain", metadata: {} })))
        .to eq("plain")
    end

    it "retries an in-stream 402 about in-flight requests too" do
      line = 'data: {"error":{"code":402,"message":"would exceed your available credits given your current in-flight requests"}}'

      expect(Samagotchi::LLM::ProviderErrors.from_sse_line(line, host: "or")).to be_a(Samagotchi::LLM::CreditsHeld)
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

    it "says one attempt, not one attempts" do
      error = Samagotchi::LLM::RetryExhausted.new(attempts: 1, last_error: Errno::ECONNRESET.new, label: "main")

      expect(error.message).to start_with("main request failed after 1 attempt: ")
      expect(error.summary).to eq("network error after 1 attempt (host main: Errno::ECONNRESET)")
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
