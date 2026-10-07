# frozen_string_literal: true

require "samagotchi/context_status"
require "samagotchi/llm_context_strategy"

RSpec.describe Samagotchi::ContextStatus do
  let(:window) { Samagotchi::ContextWindow::Resolved.new(tokens: 1_000, source: :config) }

  around do |example|
    keys = %w[SAMAGOTCHI_CONTEXT_STATUS SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS
              SAMAGOTCHI_CONTEXT_STATUS_CADENCE]
    saved = keys.to_h { |key| [key, ENV[key]] }
    example.run
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  it "reads the context.* settings once, when it is built" do
    ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "1"
    ENV["SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS"] = "10,50"
    tracker = described_class.new
    ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "4"
    ENV["SAMAGOTCHI_CONTEXT_STATUS_THRESHOLDS"] = "20,40"
    ENV["SAMAGOTCHI_CONTEXT_STATUS"] = "false"

    event = tracker.observe(600, iteration_index: 0, window: window)

    expect(event[:usage]).to include(estimated_used_tokens: 600, source: "estimate")
    expect(event[:status]).to include("bucket=50plus", "thresholds=10,50")
    expect(tracker.take_guidance[:content]).to start_with("[CONTEXT: about 60% of the context window is in use (estimated; bucket=50plus).")
    expect(tracker.take_guidance).to be_nil
  end

  it "gives the status line's value for used/window tokens, nil with context.status off or without counts" do
    expect(described_class.new.display_for(used_tokens: 4_500, window_tokens: 10_000)).to eq(est_pct: 45.0, bucket: "40plus")
    expect(described_class.new.display_for(used_tokens: nil, window_tokens: 10_000)).to be_nil
    ENV["SAMAGOTCHI_CONTEXT_STATUS"] = "false"
    expect(described_class.new.display_for(used_tokens: 4_500, window_tokens: 10_000)).to be_nil
  end

  it "counts from the conversation's last status line" do
    conversation = [{ role: "system", kind: "context", content: "[CONTEXT: about 45% ... (estimated; bucket=40plus). x]" },
                    { role: "user", content: "hi" }]

    tracker = described_class.new(conversation: conversation)

    expect(tracker.observe(1_800, iteration_index: 0, window: window)).to be_nil
    expect(tracker.display).to eq(est_pct: 45.0, bucket: "40plus")
  end

  it "adds an estimate for what the prompt grew by since the server's count" do
    tracker = described_class.new
    tracker.capture({ "usage" => { "prompt_tokens" => 100, "completion_tokens" => 10 } })
    tracker.generation_done({ total_tokens: 110 }, prompt_chars: 400, image_tokens: 0, window: window)
    expect(tracker.display).to eq(est_pct: 11.0, bucket: "under20")

    tracker.observe(800, iteration_index: 1, window: window)

    expect(tracker.display).to eq(est_pct: 20.0, bucket: "20plus")
  end

  it "says whether the status line's value is in the top bucket" do
    tracker = described_class.new
    expect(tracker).not_to be_top_bucket

    tracker.observe(3_000, iteration_index: 0, window: window)
    expect(tracker).not_to be_top_bucket
    tracker.observe(3_300, iteration_index: 1, window: window)
    expect(tracker).to be_top_bucket
  end

  it "takes what an applied edit removed off the server's count until the next one, instead of holding it" do
    tracker = described_class.new
    tracker.capture({ "usage" => { "prompt_tokens" => 600, "completion_tokens" => 10 } })
    tracker.generation_done({ total_tokens: 610 }, prompt_chars: 2_400, image_tokens: 0, window: window)

    tracker.observe(1_200, iteration_index: 1, window: window)
    expect(tracker.display).to eq(est_pct: 60.0, bucket: "60plus")

    tracker.edited!
    tracker.observe(1_200, iteration_index: 2, window: window)
    expect(tracker.display).to eq(est_pct: 30.0, bucket: "20plus")

    tracker.capture({ "usage" => { "prompt_tokens" => 320, "completion_tokens" => 10 } })
    tracker.generation_done({ total_tokens: 330 }, prompt_chars: 1_200, image_tokens: 0, window: window)
    tracker.observe(1_000, iteration_index: 3, window: window)
    expect(tracker.display).to eq(est_pct: 32.0, bucket: "20plus")
  end

  describe "under a budget (llm_context.budget_tokens)" do
    def strategy(budget, layers = [:stale])
      Samagotchi::LLMContextStrategy::Resolved.new(layers: layers, strategy: layers, source: :config, budget_tokens: budget)
    end

    it "counts the buckets against the budget, or the window when that is smaller" do
      tracker = described_class.new(llm_context: strategy(500))

      event = tracker.observe(1_600, iteration_index: 0, window: window)

      expect(event[:usage]).to include(window_tokens: 500, estimated_used_tokens: 400, estimated_pct: 80.0)
      expect(tracker).to be_top_bucket
      expect(described_class.new(llm_context: strategy(5_000)).display_for(used_tokens: 400, window_tokens: 1_000))
        .to eq(est_pct: 40.0, bucket: "40plus")
      expect(described_class.new(llm_context: strategy(nil)).display_for(used_tokens: 400, window_tokens: 1_000))
        .to eq(est_pct: 40.0, bucket: "40plus")
      expect(described_class.new(llm_context: strategy(500)).display_for(used_tokens: 400, window_tokens: 1_000))
        .to eq(est_pct: 80.0, bucket: "80plus")
    end
  end
end
