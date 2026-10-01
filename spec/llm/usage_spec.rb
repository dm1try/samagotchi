# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/usage"

RSpec.describe Samagotchi::LLM::Usage do
  it "reads server counts from a payload, through TokenUsage" do
    usage = described_class.from_payload({ "usage" => { "prompt_tokens" => 314, "completion_tokens" => 75 } })

    expect(usage).to eq(described_class.new(prompt_tokens: 314, completion_tokens: 75, source: :server))
    expect(usage.total_tokens).to eq(389)
  end

  it "is nil for a payload without counts" do
    expect(described_class.from_payload({ "content" => "hi" })).to be_nil
  end

  it "has a zero value that says there was nothing to count" do
    expect(described_class.none).to eq(described_class.new(prompt_tokens: 0, completion_tokens: 0, source: :none))
  end
end
