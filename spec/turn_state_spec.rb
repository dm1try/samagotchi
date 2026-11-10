# frozen_string_literal: true

require "samagotchi/turn_state"
require "samagotchi/cancellation_controller"
require "samagotchi/turn_context"

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
      expect(state.cancel!(:manual, turn_id: "t1")).to be(false)
    end

    describe "cancel! naming a turn" do
      let(:running) { Samagotchi::TurnContext.none(id: "t1", settings: nil) }

      before { state.begin!(context: running, controller: controller, sink: nil) }

      it "cancels the running turn when the id matches" do
        expect(state.cancel!(:user, turn_id: "t1")).to be(true)
        expect(controller.reason).to eq(:user)
      end

      it "refuses another turn's id and cancels nothing" do
        expect(state.cancel!(:user, turn_id: "t0")).to eq(:turn_mismatch)
        expect(controller.cancelled?).to be(false)
      end

      it "cancels whichever turn runs when no id is given" do
        expect(state.cancel!(:user)).to be(true)
      end
    end
  end

  describe "enqueued input ids" do
    it "allows one queued input claim and rejects repeated claims while running or ended" do
      expect(state.reserve_enqueued_id("e1")).to be(true)
      expect(state.reserve_enqueued_id("e1")).to be(false)
      expect(state.claim_enqueued_id("e1")).to be(true)
      expect(state.claim_enqueued_id("e1")).to be(false)

      state.finish_enqueued_id("e1")

      expect(state.claim_enqueued_id("e1")).to be(false)
      expect(state.reserve_enqueued_id("e1")).to be(false)
    end

    it "accepts an input-file id not previously reserved by the Bridge" do
      expect(state.claim_enqueued_id("file-id")).to be(true)
      expect(state.claim_enqueued_id("file-id")).to be(false)
    end

    it "forgets a reservation whose Bridge input could not be written" do
      expect(state.reserve_enqueued_id("e1")).to be(true)
      state.forget_enqueued_id("e1")

      expect(state.reserve_enqueued_id("e1")).to be(true)
    end

    it "marks a removed queued input ended so a late file cannot claim it" do
      expect(state.reserve_enqueued_id("removed")).to be(true)

      state.drop_enqueued_id("removed")

      expect(state.claim_enqueued_id("removed")).to be(false)
    end

    it "keeps all live ids when none can be evicted" do
      ids = ["queued", "running", *(1..described_class::ENQUEUED_ID_HISTORY).map { |index| "q#{index}" }]
      state.reserve_enqueued_id("queued")
      state.reserve_enqueued_id("running")
      state.claim_enqueued_id("running")
      ids.drop(2).each { |id| state.reserve_enqueued_id(id) }

      expect(ids.select { |id| state.enqueued_id?(id) }).to eq(ids)
    end

    it "keeps only recent ended ids while retaining active ids" do
      state.reserve_enqueued_id("active")
      (1..(described_class::ENQUEUED_ID_HISTORY + 1)).each do |index|
        id = "e#{index}"
        state.reserve_enqueued_id(id)
        state.claim_enqueued_id(id)
        state.finish_enqueued_id(id)
      end

      expect(state.enqueued_id?("e1")).to be(false)
      expect(state.enqueued_id?("e257")).to be(true)
      expect(state.enqueued_id?("active")).to be(true)
    end
  end

  describe "the turn's context (TurnContext)" do
    def context(id, **) = Samagotchi::TurnContext.none(id: id, settings: nil, **)
    let(:settings) { Samagotchi::LLM::TurnSettings.none.with(model_name: "m") }

    it "is published by begin! with the running flag, and kept as the last by finish!" do
      expect([state.context, state.last_context]).to eq([nil, nil])
      first = context("t1", author: "p:a")
      state.begin!(context: first, controller: controller, sink: nil)
      expect([state.running?, state.context, state.last_context]).to eq([true, first, nil])
      state.finish!
      expect([state.running?, state.context, state.last_context]).to eq([false, nil, first])
    end

    it "keeps the last one while the next turn runs, until that one finishes" do
      first = context("t1").with(settings: settings)
      state.begin!(context: first, controller: controller, sink: nil)
      state.finish!
      second = context("t2")
      state.begin!(context: second, controller: controller, sink: nil)
      expect([state.context, state.last_context]).to eq([second, first])
    end

    it "replace_context swaps the running turn's for the turn's own thread, one frozen value" do
      state.begin!(context: context("t1"), controller: controller, sink: nil)
      with_settings = state.context.with(settings: settings)
      state.replace_context(with_settings)
      expect(state.context).to equal(with_settings)
      expect(state.context).to be_frozen
    end

    it "replace_context refuses another thread, another turn's context, and no turn" do
      expect { state.replace_context(context("t1")) }.to raise_error(ArgumentError)
      state.begin!(context: context("t1"), controller: controller, sink: nil)
      expect { state.replace_context(context("t2")) }.to raise_error(ArgumentError, /not the running turn's/)
      other = Thread.new { state.replace_context(context("t1")) }
      expect { join!(other, "the other thread") }.to raise_error(ArgumentError, /this thread/)
    end

    it "a turn that ended before its settings keeps the last settings in the last context, its own author" do
      state.begin!(context: context("t1").with(settings: settings), controller: controller, sink: nil)
      state.finish!
      state.begin!(context: context("t2", author: "p:b"), controller: controller, sink: nil)
      state.finish!
      expect(state.last_context).to have_attributes(id: "t2", author: "p:b", settings: settings)
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

    it "drop_carried_steers drops what no turn began with, and nothing once one took it" do
      state.steer_next_turn("go", source: "user")
      expect(state.drop_carried_steers).to eq([{ text: "go", source: "user" }])
      state.begin!(controller: controller, sink: nil)
      expect(state.take_steers).to eq([])
      state.finish!

      state.steer_next_turn("again", source: "user")
      state.begin!(controller: controller, sink: nil)
      expect(state.drop_carried_steers).to eq([])
      expect(state.take_steers).to eq([{ text: "again", source: "user" }])
    end
  end

  describe "#own_controller (work done for the turn itself)" do
    it "is the controller on the thread that began the turn, nil on another, nil with no turn" do
      expect(state.own_controller).to be_nil
      state.begin!(controller: controller, sink: nil)

      expect(state.own_controller).to be(controller)
      expect(Thread.new { state.own_controller }.value).to be_nil
      expect(lock_held?).to be(false)
    end

    it "is the controller on any thread for a plugin handler" do
      state.begin!(controller: controller, sink: nil)

      expect(Thread.new { state.own_controller(handler: true) }.value).to be(controller)
    end

    it "is nil once the turn has ended (its post-turn hooks run), though the controller is still held" do
      state.begin!(controller: controller, sink: nil)
      state.ended!

      expect(state.own_controller).to be_nil
      expect(state.own_controller(handler: true)).to be_nil
      expect(state.controller).to be(controller)
    end

    it "is nil after finish!, and a next turn begins unended" do
      state.begin!(controller: controller, sink: nil)
      state.ended!
      state.finish!
      expect(state.own_controller(handler: true)).to be_nil

      next_one = Samagotchi::CancellationController.new
      state.begin!(controller: next_one, sink: nil)
      expect(state.own_controller).to be(next_one)
    end
  end
end
