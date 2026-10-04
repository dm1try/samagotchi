# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/usage"

RSpec.describe Samagotchi::LLM::Usage do
  it "reads server counts from a payload, through TokenUsage" do
    usage = described_class.from_payload({ "usage" => { "prompt_tokens" => 314, "completion_tokens" => 75 } })

    expect(usage).to eq(described_class.new(prompt_tokens: 314, completion_tokens: 75, source: :server))
    expect(usage.total_tokens).to eq(389)
  end

  it "keeps the prompt-cache counts, as the event and log fields" do
    usage = described_class.from_payload({ "usage" => { "prompt_tokens" => 15_000, "completion_tokens" => 5,
                                                        "prompt_tokens_details" => { "cached_tokens" => 14_728,
                                                                                     "cache_write_tokens" => 200 } } })

    expect(usage).to have_attributes(cached_tokens: 14_728, cache_write_tokens: 200)
    expect(usage.cache_fields).to eq(prompt_tokens: 15_000, cached_tokens: 14_728, cache_write_tokens: 200)
  end

  it "reports no cache write it wasn't told of, and no cache fields without server counts" do
    usage = described_class.new(prompt_tokens: 100, completion_tokens: 2, source: :server)

    expect(usage.cache_fields).to eq(prompt_tokens: 100, cached_tokens: 0, cache_write_tokens: nil)
    expect(described_class.none.cache_fields).to eq({})
  end

  it "is nil for a payload without counts" do
    expect(described_class.from_payload({ "content" => "hi" })).to be_nil
  end

  it "has a zero value that says there was nothing to count" do
    expect(described_class.none).to eq(described_class.new(prompt_tokens: 0, completion_tokens: 0, source: :none))
  end
end
