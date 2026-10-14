# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/refusal_memo"

RSpec.describe Samagotchi::LLM::RefusalMemo do
  subject(:memo) { described_class.new }

  it "remembers a kind per model, apart from the host's and other models'" do
    memo.remember(:thinking, "a")

    expect(memo.refused?(:thinking, "a")).to be(true)
    expect(memo.refused?(:thinking, "b")).to be(false)
    expect(memo.refused?(:thinking)).to be(false)
    expect(memo.refused?(:sampling, "a")).to be(false)
  end

  it "remembers a host-wide kind under no model" do
    memo.remember(:cache_control)

    expect(memo.refused?(:cache_control)).to be(true)
    expect(memo.refused?(:cache_control, "a")).to be(false)
  end

  it "keeps the value a refusal named, nil when none" do
    memo.remember(:output_cap, "m", 128_000)

    expect(memo[:output_cap, "m"]).to eq(128_000)
    expect(memo[:output_cap, "other"]).to be_nil
  end

  it "takes writes from several threads at once" do
    Array.new(8) { |n| Thread.new { 200.times { |i| memo.remember(:sampling, "m#{n}-#{i}") } } }.each(&:join)

    expect((0...8).all? { |n| (0...200).all? { |i| memo.refused?(:sampling, "m#{n}-#{i}") } }).to be(true)
  end
end
