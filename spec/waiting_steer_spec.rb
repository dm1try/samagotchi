# frozen_string_literal: true

require "samagotchi/waiting_steer"

RSpec.describe Samagotchi::WaitingSteer do
  let(:waiting) { described_class.new }

  it "keeps the first waiting source until taken" do
    expect(waiting.wait!("chi_send")).to be(true)
    waiting.wait!("parent_agent")
    expect(waiting.take).to eq("chi_send")
    expect(waiting.take).to be_nil
  end

  it "drops what waits when a drain delivers input, and moves the epoch" do
    epoch = waiting.epoch
    waiting.wait!(nil, epoch: epoch)
    waiting.delivered!
    expect(waiting).not_to be_waiting
    expect(waiting.wait!(nil, epoch: epoch)).to be(false)
    expect(waiting.wait!(nil, epoch: waiting.epoch)).to be(true)
    expect(waiting.take).to eq("")
  end

  it "clears" do
    waiting.wait!(nil)
    waiting.clear!
    expect(waiting).not_to be_waiting
  end
end
