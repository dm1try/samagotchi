# frozen_string_literal: true

require "samagotchi/context_status"

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
end
