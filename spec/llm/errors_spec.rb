# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/errors"
require "samagotchi/llm/http"

RSpec.describe Samagotchi::LLM::ProviderError do
  def from(status, message, **options)
    Samagotchi::LLM::ProviderErrors.from_response(status: status, body: JSON.generate(error: { message: message }), host: "fw", **options)
  end

  it "keeps an optional provider diagnosis on the error" do
    error = from(400, "Invalid signature", diagnosis: "changed_validated=system.1")

    expect(error.diagnosis).to eq("changed_validated=system.1")
    expect(from(400, "Invalid signature").diagnosis).to be_nil
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

    describe "a 404 that lists the models it has" do
      # oMLX's 404 for a model it doesn't serve, with a realistic list: far
      # longer than the summary keeps.
      def omlx_404(requested)
        ids = %w[mlx-community--Qwen3.6-35B-A3B-4bit mlx-community--Qwen3.6-35B-A3B-8bit mlx-community--Qwen3.6-27B-4bit
                 mlx-community--gemma-4-31b-it-4bit mlx-community--gemma-4-12b-it-8bit mlx-community--Llama-4-Scout-17B-16E-4bit
                 mlx-community--Mistral-Small-3.2-24B-Instruct-2506-4bit mlx-community--DeepSeek-V4-Lite-4bit
                 mlx-community--gpt-oss-20b-MXFP4-Q8 mlx-community--GLM-4.6-Air-4bit mlx-community--Kimi-Dev-72B-4bit
                 mlx-community--Devstral-Small-2-24B-4bit]
        from(404, "Model '#{requested}' not found. Available models: #{ids.join(", ")}")
      end

      it "keeps the cut message and puts the listed id the short name stands for ahead of the list" do
        error = omlx_404("Qwen3.6-35B-A3B-4bit")

        expect(error).to be_a(Samagotchi::LLM::BadRequest)
        expect(error.message.length).to eq("fw: HTTP 404: ".length + 500)
        expect(error.summary).to start_with("host fw rejected the request: HTTP 404: Model 'Qwen3.6-35B-A3B-4bit' not found; " \
                                            "did you mean 'mlx-community--Qwen3.6-35B-A3B-4bit'? " \
                                            "Available models: mlx-community--Qwen3.6-35B-A3B-4bit, ")
        expect(error.summary).not_to end_with("?")
      end

      it "suggests the id a typo is close to, even one past the cut" do
        error = omlx_404("mlx-community--Devstral-Smal-2-24B-4bit")

        expect(error.message).not_to include("Devstral-Small-2")
        expect(error.summary).to include("not found; did you mean 'mlx-community--Devstral-Small-2-24B-4bit'? Available models: ")
      end

      it "suggests an OpenRouter-style id by its last segment, its case, or a typo in its last segment" do
        list = "Available models: deepseek/deepseek-v4-flash, anthropic/claude-sonnet-5, qwen/qwen3.6-35b-a3b, " \
               "z-ai/glm-4.6"

        expect(from(404, "The model `claude-sonnet-5` does not exist. #{list}").summary)
          .to include("does not exist; did you mean 'anthropic/claude-sonnet-5'? Available models: ")
        expect(from(404, "model \"Qwen/Qwen3.6-35B-A3B\" not found. #{list}").summary)
          .to include("; did you mean 'qwen/qwen3.6-35b-a3b'? Available")
        expect(from(404, "model glm-4.5 not found. #{list}").summary).to include("; did you mean 'z-ai/glm-4.6'? Available")
      end

      it "adds nothing when no listed id is close, there is no list, or the id is listed" do
        unchanged = "host fw rejected the request: HTTP 404: "

        expect(omlx_404("nope").summary).not_to include("did you mean")
        expect(from(404, "The model was not found. Available models: wax, was2").summary).not_to include("did you mean")
        expect(from(404, "model no-such-model-p2b not found").summary)
          .to eq("#{unchanged}model no-such-model-p2b not found")
        expect(from(404, "Model 'a/b' not found. Available models: a/b, c/d").summary).not_to include("did you mean")
        expect(from(400, "Model 'qwen' not found. Available models: x/qwen").summary).not_to include("did you mean")
      end

      it "suggests no other model for a short id" do
        expect(from(404, "Model 'gpt-4' not found. Available models: gpt-4o-mini, gpt-5").summary).not_to include("did you mean")
        expect(from(404, "Model 'q1' not found. Available models: a, b, c").summary).not_to include("did you mean")
        expect(from(404, "Model 'ab' not found. Available models: ac, ad").summary).not_to include("did you mean")
        expect(from(404, "Model 'GPT-4' not found. Available models: gpt-4, gpt-5").summary)
          .to include("not found; did you mean 'gpt-4'? Available models: gpt-4, gpt-5")
      end

      it "names every nearest typo on a tie, at most three, and only the nearest" do
        expect(from(404, "Model 'qwen3-8b' not found. Available models: qwen3-4b, qwen3-9b").summary)
          .to include("; did you mean 'qwen3-4b' or 'qwen3-9b'? Available")
        expect(from(404, "Model 'qwen3-8b' not found. Available models: qwen3-1b, qwen3-2b, qwen3-4b, qwen3-9b").summary)
          .to include("; did you mean 'qwen3-1b' or 'qwen3-2b' or 'qwen3-4b'? Available")
        expect(from(404, "Model 'qwen3-8b' not found. Available models: qwen3-1bx, qwen3-9b").summary)
          .to include("; did you mean 'qwen3-9b'? Available")
      end

      it "names the ids that contain the name, closest in length first, when no typo is close" do
        error = omlx_404("Qwen3.6-35B")
        expect(error.summary).to include("; did you mean 'mlx-community--Qwen3.6-35B-A3B-4bit' or " \
                                         "'mlx-community--Qwen3.6-35B-A3B-8bit'? Available")
        expect(omlx_404("mlx-community--gemma-4-31b").summary)
          .to include("; did you mean 'mlx-community--gemma-4-31b-it-4bit'? Available")
        expect(from(404, "Model 'acme/deepseek-v4-flash:free' not found. Available models: deepseek/deepseek-v4-flash")
                 .summary).to include("; did you mean 'deepseek/deepseek-v4-flash'? Available")
        expect(from(404, "Model 'qwen3' not found. Available models: qwen3-4b").summary).not_to include("did you mean")
      end

      it "adds the hint at the end of a message without a list it can find" do
        error = Samagotchi::LLM::BadRequest.new("fw: HTTP 404: no such model", host: "fw", status: 404, hint: "did you mean 'x'?")
        expect(error.summary).to eq("host fw rejected the request: HTTP 404: no such model; did you mean 'x'?")
      end

      it "gives up quickly on a huge id or list, with no hint or three ids at most" do
        long_id = "x" * 50_000
        ids = Array.new(5000) { |i| "vendor/model-#{"y" * 150}-#{i}" }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        quoted = from(404, "Model '#{long_id}' not found. Available models: #{ids.join(", ")}")
        bare = from(404, "model #{"1" * 50_000} not found. Available models: #{ids.join(", ")}")
        listed = from(404, "Model 'vendor/model-#{"y" * 150}-x' not found. Available models: #{ids.join(", ")}")

        # ~0.3 s alone; the bound catches a quadratic match (seconds), not a
        # loaded runner (0.5 s failed under parallel_rspec -n 8).
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(2.0)
        [quoted, bare].each { |error| expect(error.summary).not_to include("did you mean") }
        expect(listed.hint.scan("' or '").size).to eq(2)
      end
    end

    it "covers server and protocol errors" do
      expect(from(503, "busy").summary).to eq("server error from host fw: HTTP 503: busy")
      expect(Samagotchi::LLM::ProtocolError.new("fw: malformed stream chunk: x", host: "fw").summary)
        .to eq("unexpected response from host fw: malformed stream chunk: x")
    end
  end

  describe "Anthropic error objects (by error.type, without a numeric code)" do
    def anthropic(name) = File.read(File.expand_path("../fixtures/providers/anthropic/#{name}", __dir__))

    def from_json(raw) = Samagotchi::LLM::ProviderErrors.from_error_json(raw, host: "msg")

    def typed(type) = JSON.generate(type: "error", error: { type: type, message: "words" })

    it "maps each Anthropic error type to its status and kind" do
      expected = {
        "invalid_request_error" => [400, Samagotchi::LLM::BadRequest],
        "authentication_error" => [401, Samagotchi::LLM::AuthError],
        "billing_error" => [402, Samagotchi::LLM::OutOfCredits],
        "permission_error" => [403, Samagotchi::LLM::AuthError],
        "not_found_error" => [404, Samagotchi::LLM::BadRequest],
        "request_too_large" => [413, Samagotchi::LLM::BadRequest],
        "rate_limit_error" => [429, Samagotchi::LLM::RateLimited],
        "api_error" => [500, Samagotchi::LLM::ServerError],
        "overloaded_error" => [529, Samagotchi::LLM::ServerError],
        "timeout_error" => [504, Samagotchi::LLM::ServerError]
      }

      expected.each do |type, (status, klass)|
        error = from_json(typed(type))
        expect([type, error.status, error.class]).to eq([type, status, klass])
      end
    end

    it "retries only the rate limit and the server's own failures" do
      retried = %w[rate_limit_error api_error overloaded_error]
      %w[invalid_request_error authentication_error billing_error permission_error not_found_error
         request_too_large].each { |type| expect(from_json(typed(type))).not_to be_retryable, type }
      retried.each { |type| expect(from_json(typed(type))).to be_retryable, type }
    end

    it "classifies a mid-stream error event by its type (overloaded: a retryable server error)" do
      line = anthropic("stream_error.hand-written.sse").lines.find { |l| l.start_with?("data:") && l.include?('"error"') }
      error = Samagotchi::LLM::ProviderErrors.from_sse_line(line.chomp, host: "msg")

      expect(error).to be_a(Samagotchi::LLM::ServerError)
      expect(error.status).to eq(529)
      expect(error).to be_retryable
      expect(error.summary).to eq("server error from host msg: HTTP 529: Overloaded")
    end

    it "maps Splash's unknown model (404 not_found_error) to a bad request, not retried, with or without the status" do
      body = anthropic("splash_error_404_unknown_model.json")
      by_status = Samagotchi::LLM::ProviderErrors.from_response(status: 404, body: body, host: "splash")

      [by_status, from_json(body)].each do |error|
        expect(error).to be_a(Samagotchi::LLM::BadRequest)
        expect(error.status).to eq(404)
        expect(error).not_to be_retryable
        expect(error).not_to be_reasoning_refused
      end
      expect(by_status.summary).to eq("host splash rejected the request: HTTP 404: model no-such-model-p2b not found")
    end

    it "maps a Google-style string code (Fireworks' pre-routing errors) to its status, before the type" do
      expected = { "NOT_FOUND" => 404, "INVALID_ARGUMENT" => 400, "UNAUTHENTICATED" => 401, "PERMISSION_DENIED" => 403,
                   "RESOURCE_EXHAUSTED" => 429 }

      expected.each do |code, status|
        error = from_json(JSON.generate(error: { code: code, message: "words" }))
        expect([code, error.status, error.retryable?]).to eq([code, status, status == 429])
      end
    end

    it "takes Fireworks' unknown model (code NOT_FOUND) as a 404 bad request, not retried, also in a 200's body" do
      body = anthropic("fireworks_error_404_not_found.hand-written.json")
      error = Samagotchi::LLM::ProviderErrors.from_error_body(body, host: "fw")

      expect(error).to be_a(Samagotchi::LLM::BadRequest)
      expect([error.status, error.retryable?]).to eq([404, false])
    end

    it "no longer retries an OpenAI-shaped invalid request whose code is not a number" do
      raw = JSON.generate(error: { message: "Invalid value for 'n'", type: "invalid_request_error", param: "n", code: nil })
      named = JSON.generate(error: { message: "bad", type: "invalid_request_error", code: "invalid_value" })

      [raw, named].each do |body|
        error = from_json(body)
        expect(error).to be_a(Samagotchi::LLM::BadRequest)
        expect(error.status).to eq(400)
        expect(error).not_to be_retryable
      end
    end

    it "reads Anthropic's \"prompt is too long\" as a context overflow" do
      body = anthropic("error_400_prompt_too_long.hand-written.json")
      error = Samagotchi::LLM::ProviderErrors.from_response(status: 400, body: body, host: "msg")

      expect(error).to be_a(Samagotchi::LLM::BadRequest)
      expect(error).to be_context_overflow
      expect(error.summary).to eq("the conversation is too long for host msg's context window: " \
                                  "HTTP 400: prompt is too long: 208310 tokens > 200000 maximum")
      expect(from_json(body)).to be_context_overflow
      expect(from(400, "the prompt is too long for a haiku")).not_to be_context_overflow
    end

    it "reads Anthropic's \"input length and max_tokens exceed context limit\" as a context overflow" do
      message = "input length and `max_tokens` exceed context limit: 188240 + 21333 > 200000, " \
                "decrease input length or `max_tokens` and try again"

      expect(from(400, message)).to be_context_overflow
      expect(from(400, "input length and max_tokens exceed context limit: 10 + 5 > 12")).to be_context_overflow
      expect(from(400, "max_tokens exceed context limit for this plan")).not_to be_context_overflow
    end

    it "tells a thinking block's signature 400 (bound elsewhere, or unreadable) apart, without refusing reasoning" do
      %w[error_400_signature_other_conversation.hand-written.json error_400_signature_invalid.hand-written.json
         claude_error_400_signature_system_changed.json]
        .each do |name|
          error = Samagotchi::LLM::ProviderErrors.from_response(status: 400, body: anthropic(name), host: "msg")

          expect(error).to be_a(Samagotchi::LLM::BadRequest)
          expect(error).to be_thinking_signature, name
          expect(error).not_to be_thinking_binding_unsupported, name
          expect(error).not_to be_reasoning_refused, name
          expect(error).not_to be_retryable
        end
      expect(from_json(anthropic("error_400_signature_other_conversation.hand-written.json"))).to be_thinking_signature
    end

    it "tells a refused binding control (the block_binding field or the beta header) apart, without refusing reasoning" do
      %w[error_400_block_binding_extra.hand-written.json error_400_binding_beta_unknown.hand-written.json].each do |name|
        error = Samagotchi::LLM::ProviderErrors.from_response(status: 400, body: anthropic(name), host: "msg")

        expect(error).to be_thinking_binding_unsupported, name
        expect(error).not_to be_thinking_signature, name
        expect(error).not_to be_reasoning_refused, name
      end
    end

    it "still marks the thinking configs a model refuses as refused reasoning, and sets neither predicate" do
      %w[error_400_disabled_refused.hand-written.json error_400_budget_tokens_refused.hand-written.json
         splash_error_400_between_tools.json error_400_disabled_between_tools.hand-written.json].each do |name|
        error = Samagotchi::LLM::ProviderErrors.from_response(status: 400, body: anthropic(name), host: "msg")

        expect(error).to be_reasoning_refused, name
        expect(error).not_to be_thinking_signature, name
        expect(error).not_to be_thinking_binding_unsupported, name
      end
    end

    it "sets neither predicate on other errors" do
      [from(400, "invalid temperature"), from(400, "Reasoning is mandatory for this endpoint and cannot be disabled."),
       from(404, "model not found"), from_json(typed("invalid_request_error"))].each do |error|
        expect(error).not_to be_thinking_signature
        expect(error).not_to be_thinking_binding_unsupported
      end
    end

    it "keeps a numeric code first, and an unknown or missing type a retryable 500" do
      expect(from_json(JSON.generate(error: { code: 503, type: "invalid_request_error", message: "x" })).status).to eq(503)
      expect(from_json(JSON.generate(error: { code: "429", type: "api_error", message: "x" })).status).to eq(429)

      [JSON.generate(error: { type: "server_error", code: nil, message: "x" }), JSON.generate(error: { message: "x" })]
        .each do |body|
          error = from_json(body)
          expect(error).to be_a(Samagotchi::LLM::ServerError)
          expect(error.status).to eq(500)
          expect(error).to be_retryable
        end
    end
  end

  describe "a sampling field refused" do
    it "is sampling_refused?, not reasoning_refused?, though Claude's message says thinking" do
      error = Samagotchi::LLM::ProviderErrors.from_response(
        status: 400, host: "h",
        body: { type: "error", error: { type: "invalid_request_error",
                                        message: "temperature may only be set to 1 when thinking is enabled" } }.to_json
      )

      expect(error).to have_attributes(sampling_refused?: true, reasoning_refused?: false)
      other = Samagotchi::LLM::ProviderErrors.from_response(status: 400, host: "h", body: '{"error":{"message":"reasoning is mandatory"}}')
      expect(other).to have_attributes(sampling_refused?: false, reasoning_refused?: true)
    end
  end

  describe "an assistant turn sent back without its thinking block" do
    it "is not reasoning_refused? (the history is wrong, thinking isn't refused)" do
      message = "messages.1.content.0.type: Expected `thinking` or `redacted_thinking`, but found `tool_use`. When " \
                "`thinking` is enabled, a final `assistant` message must start with a thinking block."
      error = Samagotchi::LLM::ProviderErrors.from_response(
        status: 400, host: "h", body: { type: "error", error: { type: "invalid_request_error", message: message } }.to_json
      )

      expect(error).to be_a(Samagotchi::LLM::BadRequest)
      expect(error).to have_attributes(reasoning_refused?: false, sampling_refused?: false)
    end
  end

  describe Samagotchi::LLM::TLSError do
    # Messages as Ruby's OpenSSL (3.x) and Net::HTTP raise them.
    {
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: unexpected eof while reading" => nil,
      "SSL_connect SYSCALL returned=5 errno=0 peeraddr=10.0.0.7:443 state=SSLv3/TLS write client hello" => nil,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: connection reset by peer" => nil,
      "SSL_read: unexpected eof while reading" => nil,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: " \
      "certificate verify failed (self-signed certificate)" => :certificate,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: " \
      "certificate verify failed (unable to get local issuer certificate)" => :certificate,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: " \
      "certificate verify failed (certificate has expired)" => :certificate,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: " \
      "certificate verify failed (hostname mismatch)" => :hostname,
      'hostname "gw.example" does not match the server certificate' => :hostname,
      "SSL_connect returned=1 errno=0 peeraddr=(null) state=SSLv3/TLS write client hello: " \
      "wrong version number" => :scheme,
      "SSL_connect returned=1 errno=0 peeraddr=10.0.0.7:443 state=error: packet length too long" => :scheme
    }.each do |message, problem|
      it "classifies #{message.inspect} as #{problem || "transient"}" do
        error = OpenSSL::SSL::SSLError.new(message)

        expect(Samagotchi::LLM::HTTP.tls_problem(error)).to eq(problem)
        expect(Samagotchi::LLM::HTTP.network_error?(error)).to be(true)
      end
    end

    it "leaves errors that aren't TLS errors to the network-error rules" do
      expect(Samagotchi::LLM::HTTP.tls_problem(EOFError.new("wrong version number"))).to be_nil
    end

    it "keeps the OpenSSL reason, not Ruby's SSL_connect prefix" do
      expect(described_class.reason_for("SSL_connect returned=1 errno=0 peeraddr=(null) " \
                                        "state=SSLv3/TLS write client hello: wrong version number"))
        .to eq("wrong version number")
      expect(described_class.reason_for('hostname "gw" does not match the server certificate'))
        .to eq('hostname "gw" does not match the server certificate')
    end

    it "names the host, its address and what to check" do
      error = described_class.new(host: "gw", address: "gw.example:443", problem: :certificate,
                                  reason: "certificate verify failed (unable to get local issuer certificate)")

      expect(error).to be_a(Samagotchi::LLM::ConnectionError)
      expect(error).not_to be_retryable
      expect(error.message).to eq("gw: TLS failed at gw.example:443: certificate verify failed " \
                                  "(unable to get local issuer certificate)")
      expect(error.summary).to eq("can't reach host gw at gw.example:443 over TLS (certificate verify failed " \
                                  "(unable to get local issuer certificate)) — is its CA trusted? set SSL_CERT_FILE " \
                                  "to a CA bundle that has it")
    end
  end
end
