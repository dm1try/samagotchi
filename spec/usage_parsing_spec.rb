# frozen_string_literal: true

require "json"
require "samagotchi/token_usage"
require "samagotchi/context_usage"

# TokenUsage (SessionMetrics, /stats) and ContextUsage (the kernel's context
# status and the TUI status line) read the same token fields from a streamed
# payload. This table pins what each returns for the payload shapes we see.
RSpec.describe "Usage parsing" do
  def tokens(payload) = Samagotchi::TokenUsage.from_payload(payload)&.to_h&.values_at(:prompt_tokens, :completion_tokens)
  def context(payload, **kw) = Samagotchi::ContextUsage.normalize(payload, **kw)

  {
    "llama.cpp streamed timings" => [{ "timings" => { "prompt_n" => 120, "predicted_n" => 7 } }, [120, 7]],
    "llama.cpp final counts" => [{ "tokens_evaluated" => 130, "tokens_predicted" => 40 }, [130, 40]],
    "OpenAI usage" => [{ "usage" => { "prompt_tokens" => 11, "completion_tokens" => 3, "total_tokens" => 14 } }, [11, 3]],
    "symbol keys" => [{ usage: { prompt_tokens: 5, completion_tokens: 2 } }, [5, 2]],
    "integer floats" => [{ "usage" => { "prompt_tokens" => 50.0, "completion_tokens" => 2.0 } }, [50, 2]]
  }.each do |shape, (payload, expected)|
    it "reads #{shape} the same way in both" do
      expect(tokens(payload)).to eq(expected)
      expect(context(payload).values_at(:prompt_tokens, :completion_tokens)).to eq(expected)
    end
  end

  # Recorded from llama.cpp with most of the prompt in the prompt cache: the
  # last event's timings.prompt_n is only the uncached part.
  it "reads the whole prompt from a cached native /completion stream" do
    path = File.expand_path("fixtures/providers/llamacpp/completion_cached_stream.sse", __dir__)
    events = File.readlines(path).filter_map { |line| JSON.parse(line.delete_prefix("data: ")) if line.start_with?("data: ") }
    expect(events.last.dig("timings", "prompt_n")).to eq(4)
    expect(events.map { |event| tokens(event) }.uniq.last).to eq([489, 8])
    expect(events.map { |event| tokens(event)[0] }.uniq).to eq([489])
  end

  describe "the last chunk's breakdown and speeds" do
    def last_event(path)
      File.readlines(File.expand_path(path, __dir__)).filter_map do |line|
        JSON.parse(line.delete_prefix("data: ")) if line.start_with?("data: {")
      end.last
    end

    it "reads llama.cpp's OpenAI endpoint: cached from usage, exact speeds from timings" do
      usage = Samagotchi::TokenUsage.from_payload(last_event("fixtures/providers/openai/reasoning_tool_stream.sse"))
      expect(usage).to have_attributes(prompt_tokens: 307, completion_tokens: 56, cached_tokens: 279,
                                       reasoning_tokens: nil, cost: nil, predicted_ms: 1740.742)
      expect(usage.predicted_per_second).to be_within(0.001).of(31.596)
      expect(usage.prompt_per_second).to be_within(0.001).of(308.816)
    end

    it "has no cached count when nothing came from the cache" do
      usage = Samagotchi::TokenUsage.from_payload(last_event("fixtures/providers/openai/text_stream.sse"))
      expect(usage.cached_tokens).to be_nil
      expect(usage.predicted_per_second).to be_within(0.001).of(90.882)
    end

    it "reads llama.cpp native: cache_n, not tokens_cached (which counts the new tokens too)" do
      usage = Samagotchi::TokenUsage.from_payload(last_event("fixtures/providers/llamacpp/completion_cached_stream.sse"))
      expect(usage).to have_attributes(prompt_tokens: 489, completion_tokens: 8, cached_tokens: 485, predicted_ms: 81.331)
      expect(usage.predicted_per_second).to be_within(0.001).of(86.068)
    end

    # Hand-written from the 2026-10-03 probe (deepseek-v4.1-flash via OpenRouter):
    # cost on every request, cache and reasoning breakdowns, no timings.
    it "reads OpenRouter's cost, cached and reasoning tokens, with no speeds" do
      payload = { "choices" => [], "usage" => {
        "prompt_tokens" => 5210, "completion_tokens" => 340, "total_tokens" => 5550, "cost" => 0.00123, "is_byok" => false,
        "prompt_tokens_details" => { "cached_tokens" => 4864, "cache_write_tokens" => 0 },
        "completion_tokens_details" => { "reasoning_tokens" => 212 }
      } }
      usage = Samagotchi::TokenUsage.from_payload(payload)
      expect(usage).to have_attributes(prompt_tokens: 5210, completion_tokens: 340, cached_tokens: 4864,
                                       reasoning_tokens: 212, cost: 0.00123, predicted_per_second: nil,
                                       prompt_per_second: nil, predicted_ms: nil)
    end

    it "reads OpenRouter's cache writes (Anthropic models), nil when it wrote none" do
      payload = { "usage" => { "prompt_tokens" => 14_800, "completion_tokens" => 5,
                               "prompt_tokens_details" => { "cached_tokens" => 0, "cache_write_tokens" => 14_728 } } }
      expect(Samagotchi::TokenUsage.from_payload(payload)).to have_attributes(cached_tokens: nil, cache_write_tokens: 14_728)
      payload["usage"]["prompt_tokens_details"] = { "cached_tokens" => 14_728, "cache_write_tokens" => 0 }
      expect(Samagotchi::TokenUsage.from_payload(payload)).to have_attributes(cached_tokens: 14_728, cache_write_tokens: nil)
    end

    it "keeps a zero cost (a free model) and skips a broken one" do
      free = { "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0 } }
      expect(Samagotchi::TokenUsage.from_payload(free).cost).to eq(0.0)
      broken = { "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "cost" => "n/a" } }
      expect(Samagotchi::TokenUsage.from_payload(broken).cost).to be_nil
    end
  end

  it "has no numbers for an empty payload" do
    expect(tokens({})).to be_nil
    expect(context({})).to be_nil
  end

  # ContextUsage used Integer() and read "010" as octal 8 and skipped "50.0".
  it "reads numeric strings as decimal in both" do
    payload = { "usage" => { "prompt_tokens" => "010", "completion_tokens" => "50.0", "total_tokens" => "060" } }
    expect(tokens(payload)).to eq([10, 50])
    expect(context(payload)).to include(prompt_tokens: 10, completion_tokens: 50, total_tokens: 60)
  end

  describe "ContextUsage's own fields" do
    it "totals, n_past and the window: the payload's n_ctx wins over the caller's window" do
      result = context({ "timings" => { "prompt_n" => 100, "predicted_n" => 20 }, "n_past" => 300, "n_ctx" => 1000 },
                       window_tokens: 4096)
      expect(result).to include(total_tokens: 300, context_window_tokens: 1000, ctx_pct: 30.0)
    end

    it "sums prompt and completion when there is no total, and uses the caller's window" do
      result = context({ "tokens_evaluated" => 100, "tokens_predicted" => 28 }, window_tokens: 1280)
      expect(result).to include(total_tokens: 128, context_window_tokens: 1280, ctx_pct: 10.0)
    end
  end
end
