# frozen_string_literal: true

require "samagotchi/token_usage"
require "samagotchi/context_usage"

# TokenUsage (SessionMetrics, /stats) and ContextUsage (the kernel's context
# status and the TUI status line) read the same token fields from a streamed
# payload. This table pins what each returns for the payload shapes we see.
RSpec.describe "Usage parsing" do
  def tokens(payload) = Samagotchi::TokenUsage.from_payload(payload)&.values_at(:prompt_tokens, :completion_tokens)
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

  it "has no numbers for an empty payload" do
    expect(tokens({})).to be_nil
    expect(context({})).to be_nil
  end

  describe "where they disagree today" do
    let(:payload) { { "usage" => { "prompt_tokens" => "010", "completion_tokens" => "50.0" } } }

    it "TokenUsage reads numeric strings as decimal" do
      expect(tokens(payload)).to eq([10, 50])
    end

    it "ContextUsage reads \"010\" as octal and skips \"50.0\"" do
      expect(context(payload).values_at(:prompt_tokens, :completion_tokens)).to eq([8, nil])
    end
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
