# frozen_string_literal: true

require "samagotchi/reprefill_meter"

# The re-prefill baseline both loops of an Engine count against.
RSpec.describe Samagotchi::ReprefillMeter do
  subject(:meter) { described_class.new }

  let(:host) { Object.new }

  it "counts what the server prefilled again of the last request's prompt, from the second request on" do
    expect(meter.tokens("m", client: host, prompt: 1_000, cached: 900)).to be_nil
    expect(meter.tokens("m", client: host, prompt: 1_500, cached: 600)).to eq(400)
    # Under REPREFILL_MIN_TOKENS (a cache block's rounding) is none; so is a cold cache.
    expect(meter.tokens("m", client: host, prompt: 1_600, cached: 1_500)).to be_nil
    expect(meter.tokens("m", client: host, prompt: 1_700, cached: 0)).to be_nil
    expect(meter.tokens("m", client: host, prompt: 1_800, cached: 100)).to eq(1_600)
  end

  it "starts over on another model, another client (the same bare model on another host) and a reset" do
    meter.tokens("m", client: host, prompt: 5_000, cached: 0)
    expect(meter.tokens("other", client: host, prompt: 5_200, cached: 1_000)).to be_nil
    expect(meter.tokens("m", client: Object.new, prompt: 5_400, cached: 1_000)).to be_nil
    expect(meter.tokens("m", client: host, prompt: 5_600, cached: 1_000)).to be_nil
    expect(meter.tokens("m", client: host, prompt: 5_800, cached: 1_000)).to eq(4_600)

    meter.reset!

    expect(meter.tokens("m", client: host, prompt: 6_000, cached: 1_000)).to be_nil
  end

  it "keeps the baseline across a request with no prompt count" do
    meter.tokens("m", client: host, prompt: 2_000, cached: 0)
    expect(meter.tokens("m", client: host, prompt: 0, cached: 500)).to eq(1_500)
  end
end
