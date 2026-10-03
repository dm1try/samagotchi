# frozen_string_literal: true

require "samagotchi/turn_state"
require "samagotchi/cancellation_controller"

RSpec.describe Samagotchi::TurnState do
  subject(:state) { described_class.new(clock: -> { now }) }

  let(:now) { 100.0 }
  let(:controller) { Samagotchi::CancellationController.new }

  def lock_held? = state.instance_variable_get(:@lock).mon_owned?

  describe "the activity clock" do
    it "starts at the clock's now with sequence 0" do
      expect([state.last_activity_at, state.activity_seq]).to eq([100.0, 0])
    end

    it "record_activity moves the clock and advances the sequence" do
      state.record_activity(130)
      state.record_activity
      expect([state.last_activity_at, state.activity_seq]).to eq([100.0, 2])
      state.record_activity(150)
      expect(state.last_activity_at).to eq(150.0)
    end

    it "restart_clock! moves the clock without counting activity" do
      clock = [100.0]
      state = described_class.new(clock: -> { clock.first })
      clock[0] = 140.0
      state.restart_clock!
      expect([state.last_activity_at, state.activity_seq]).to eq([140.0, 0])
    end
  end

  describe "a turn" do
    it "is idle at first: not running, no controller, no sink" do
      expect([state.running?, state.controller, state.in_turn_sink]).to eq([false, nil, [false, nil]])
    end

    it "begin! sets the flag, controller and sink together; finish! clears them" do
      sink = ->(_event) {}
      state.begin!(controller: controller, sink: sink)
      expect([state.running?, state.controller, state.in_turn_sink]).to eq([true, controller, [true, sink]])

      state.finish!
      expect([state.running?, state.controller, state.in_turn_sink]).to eq([false, nil, [false, nil]])
    end

    it "cancel! cancels the turn's controller outside the lock" do
      held = nil
      allow(controller).to receive(:cancel!).and_wrap_original do |original, reason|
        held = lock_held?
        original.call(reason)
      end
      state.begin!(controller: controller, sink: nil)

      expect(state.cancel!(:manual)).to be(true)
      expect(controller.reason).to eq(:manual)
      expect(held).to be(false)
    end

    it "cancel! is false with no turn" do
      expect(state.cancel!(:manual)).to be(false)
    end
  end

  describe "steers" do
    it "are refused with no turn running, and when blank" do
      expect(state.steer("hi", source: "x")).to be(false)
      state.begin!(controller: controller, sink: nil)
      expect(state.steer("  ", source: "x")).to be(false)
      expect(state.take_steers).to eq([])
    end

    it "queue stripped during a turn and are taken once" do
      state.begin!(controller: controller, sink: nil)
      expect(state.steer(" a ", source: :plugin)).to be(true)
      expect(state.take_steers).to eq([{ text: "a", source: "plugin" }])
      expect(state.take_steers).to eq([])
    end

    it "finish! hands back the ones never taken" do
      state.begin!(controller: controller, sink: nil)
      state.steer("left", source: "x")
      expect(state.finish!).to eq([{ text: "left", source: "x" }])
      expect(state.take_steers).to eq([])
      expect(state.steer("after", source: "x")).to be(false)
    end

    it "steer_next_turn waits for the turn that begins, then queues like a steer" do
      expect(state.steer_next_turn("go", source: :parent_agent)).to be(true)
      expect(state.steer_next_turn(" ", source: "x")).to be(false)
      expect(state.take_steers).to eq([])
      state.begin!(controller: controller, sink: nil)
      expect(state.take_steers).to eq([{ text: "go", source: "parent_agent" }])
      state.finish!
      state.begin!(controller: controller, sink: nil)
      expect(state.take_steers).to eq([])
    end
  end
end
