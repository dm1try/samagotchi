# frozen_string_literal: true

require "samagotchi/context_usage"

RSpec.describe Samagotchi::ContextUsage do
  # Final streamed chunk of llama.cpp's /completion (trimmed): token counts,
  # but no n_ctx.
  let(:llama_cpp_final_chunk) do
    { "stop" => true, "tokens_predicted" => 4, "tokens_evaluated" => 3, "tokens_cached" => 6,
      "timings" => { "cache_n" => 0, "prompt_n" => 3, "predicted_n" => 4 } }
  end

  around do |example|
    original = ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"]
    ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "999"
    example.run
  ensure
    ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = original
  end

  it "leaves the window unset when the payload does not report one" do
    usage = described_class.normalize(llama_cpp_final_chunk)

    expect(usage).to include(prompt_tokens: 3, completion_tokens: 4, context_window_tokens: nil, ctx_pct: nil)
  end

  it "computes ctx_pct against the window the caller resolved" do
    usage = described_class.normalize(llama_cpp_final_chunk, window_tokens: 100)

    expect(usage).to include(context_window_tokens: 100, total_tokens: 7)
    expect(usage[:ctx_pct]).to be_within(0.01).of(7.0)
  end

  it "prefers a window the payload reports over the caller's" do
    usage = described_class.normalize(llama_cpp_final_chunk.merge("n_ctx" => 1_000), window_tokens: 100)

    expect(usage[:context_window_tokens]).to eq(1_000)
  end
end
