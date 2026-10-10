# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_wakes"

RSpec.describe Samagotchi::WorkerWakes do
  let(:now) { [100.0] }
  let(:budget) { [3] }
  let!(:wakes) { described_class.new(grace: 2.0, clock: -> { now[0] }, max: -> { budget[0] }) }

  def pass(seconds) = now[0] += seconds

  describe "the start grace" do
    it "counts down from the start" do
      expect(wakes.grace_left).to eq(2.0)
      expect(wakes.in_grace?).to be(true)
      pass(2.0)
      expect(wakes.in_grace?).to be(false)
    end

    it "shortens the idle sleep only while a wake is due within it" do
      pass(1.5)
      expect(wakes.idle_wait(5) { true }).to eq(0.5)
      expect(wakes.idle_wait(5) { false }).to eq(5)
      expect(wakes.idle_wait(0.1) { true }).to eq(0.1)
      pass(1.0)
      expect(wakes.idle_wait(5) { true }).to eq(5)
    end
  end

  describe "#delegate_state" do
    it "is :due while reports wait and the budget lasts, :budget once it is spent" do
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
      3.times { wakes.count! }
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:budget)
    end

    it "is nil with no reports waiting, with a continue offer or while paused, and asks for reports last" do
      asked = 0
      expect(wakes.delegate_state(awaiting_continue: false) { false }).to be_nil
      expect(wakes.delegate_state(awaiting_continue: true) { asked += 1 }).to be_nil
      wakes.pause!
      expect(wakes.delegate_state(awaiting_continue: false) { asked += 1 }).to be_nil
      expect(asked).to eq(0)
    end

    it "ignores the start grace (the idle sleep waits it out)" do
      expect(wakes.in_grace?).to be(true)
      expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
    end
  end

  describe "#context_open?" do
    before { pass(2.0) }

    it "opens past the grace, with no offer, unpaused and under the budget" do
      expect(wakes.context_open?(awaiting_continue: false, names: ["ci"])).to be(true)
      expect(wakes.context_open?(awaiting_continue: true, names: ["ci"])).to be(false)
      wakes.pause!
      expect(wakes.context_open?(awaiting_continue: false, names: ["ci"])).to be(false)
    end

    it "stays shut within the start grace" do
      fresh = described_class.new(grace: 2.0, clock: -> { now[0] }, max: -> { 3 })
      expect(fresh.context_open?(awaiting_continue: false, names: ["ci"])).to be(false)
    end

    it "logs the sources the spent budget holds" do
      3.times { wakes.count! }
      expect(Samagotchi::Log).to receive(:info).with(:worker, "context_wake_held", reason: "max_wakes", names: "ci,docs")
      expect(wakes.context_open?(awaiting_continue: false, names: %w[ci docs])).to be(false)
    end
  end

  it "counts wake turns, and a human's input resets the count, the pause and the budget notice" do
    expect(wakes.count!).to eq(1)
    expect(wakes.count!).to eq(2)
    wakes.pause!
    expect(wakes.notice_budget!).to be(true)
    expect(wakes.notice_budget!).to be(false)

    expect(wakes.delegate_state(awaiting_continue: false) { true }).to be_nil
    wakes.human_input!
    expect(wakes.in_a_row).to eq(0)
    expect(wakes.delegate_state(awaiting_continue: false) { true }).to eq(:due)
    expect(wakes.notice_budget!).to be(true)
  end

  it "hands a wake turn's reports over once" do
    wakes.hand_over([:report])
    expect(wakes.take_handed).to eq([:report])
    expect(wakes.take_handed).to be_nil
    wakes.hand_over([:report])
    wakes.drop_handed
    expect(wakes.take_handed).to be_nil
  end

  describe "#max" do
    let(:wakes) { described_class.new(grace: 0) }

    it "reads session.max_wakes, falling back to the default for a value that isn't a positive integer" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.max_wakes").and_return("4", "0", "lots", nil)
      expect([wakes.max, wakes.max, wakes.max, wakes.max])
        .to eq([4, *[Samagotchi::ChildRing::MAX_WAKES_DEFAULT] * 3])
    end
  end
end
