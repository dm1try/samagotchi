# frozen_string_literal: true

require "samagotchi/config"
require "samagotchi/model_price"

# hosts.<name>.models.<id>.price: USD per 1M tokens, what a generation's
# cost is estimated from when the provider reports none.
RSpec.describe Samagotchi::ModelPrice do
  def parse(raw) = described_class.parse(raw, "hosts.work.models.rr/x")

  it "reads input, cache_read, cache_write and output; an unset cache rate is the input rate" do
    expect(parse("input" => 0.27, "cache_read" => 0.07, "output" => 1.1))
      .to eq(described_class.new(input: 0.27, cache_read: 0.07, cache_write: 0.27, output: 1.1))
    expect(parse("input" => 1, "output" => 2).to_h).to eq(input: 1, cache_read: 1, cache_write: 1, output: 2)
  end

  it "is nil when unset" do
    expect(parse(nil)).to be_nil
  end

  it "warns once and is unset without input or output, or with a value that isn't a number >= 0" do
    expect(Samagotchi::ConfigFile).to receive(:warn_once)
      .with("Warning: hosts.work.models.rr/x.price needs input and output, each a number >= 0 (USD per 1M tokens); ignored")
      .exactly(6).times

    expect(parse("input" => 1)).to be_nil
    expect(parse("input" => 1, "output" => "cheap")).to be_nil
    expect(parse("input" => 1, "output" => 2, "cache_read" => -1)).to be_nil
    expect(parse(3)).to be_nil
    expect(parse("input" => Float::INFINITY, "output" => 1)).to be_nil
    expect(parse("input" => 1, "output" => Float::NAN)).to be_nil
  end

  describe "#cost" do
    let(:price) { described_class.new(input: 2.0, cache_read: 0.5, cache_write: 4.0, output: 10.0) }

    it "prices the uncached prompt, the cached reads, the cache writes and the completion, per 1M tokens" do
      # prompt_tokens holds the cached reads and the cache writes (OpenAI usage).
      cost = price.cost(prompt_tokens: 1_000_000, cached_tokens: 600_000, cache_write_tokens: 100_000,
                        completion_tokens: 50_000)

      expect(cost).to be_within(1e-9).of(((300_000 * 2.0) + (600_000 * 0.5) + (100_000 * 4.0) + (50_000 * 10.0)) / 1e6)
    end

    it "never prices the uncached part below zero" do
      expect(price.cost(prompt_tokens: 10, cached_tokens: 100, cache_write_tokens: 0, completion_tokens: 0))
        .to be_within(1e-12).of(100 * 0.5 / 1e6)
    end
  end

  it "goes back to its written form" do
    expect(parse("input" => 1, "output" => 2).to_config).to eq("input" => 1, "cache_read" => 1, "cache_write" => 1, "output" => 2)
  end
end
