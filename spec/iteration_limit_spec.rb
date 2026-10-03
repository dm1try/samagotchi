# frozen_string_literal: true

require "samagotchi/iteration_limit"

RSpec.describe Samagotchi::IterationLimit do
  it "gives a turn 100 iterations, and a --no-interrupt one 1000" do
    expect(described_class.for).to eq(100)
    expect(described_class.for(no_interrupt: false)).to eq(100)
    expect(described_class.for(no_interrupt: true)).to eq(1000)
  end
end
