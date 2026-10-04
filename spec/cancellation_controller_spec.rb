# frozen_string_literal: true

require "spec_helper"
require "samagotchi/cancellation_controller"
require "samagotchi/client"

RSpec.describe Samagotchi::CancellationController do
  subject(:controller) { described_class.new }

  it "cancels once, keeping the first reason" do
    expect(controller.cancel!(:ctrl_c)).to be(true)
    expect(controller.cancel!(:manual)).to be(false)
    expect(controller).to be_cancelled
    expect(controller.reason).to eq(:ctrl_c)
  end

  it "calls listeners on cancel, but not removed ones" do
    calls = []
    kept = controller.on_cancel { |reason| calls << [:kept, reason] }
    removed = controller.on_cancel { |reason| calls << [:removed, reason] }
    controller.remove_listener(removed)

    controller.cancel!(:user)

    expect(kept).to be_a(Integer)
    expect(calls).to eq([%i[kept user]])
  end

  it "runs a listener added after the cancel at once" do
    controller.cancel!(:manual)
    reasons = []

    expect(controller.on_cancel { |reason| reasons << reason }).to be_nil
    expect(reasons).to eq([:manual])
  end

  it "isolates a failing listener" do
    reasons = []
    controller.on_cancel { raise "boom" }
    controller.on_cancel { |reason| reasons << reason }

    expect { controller.cancel! }.not_to raise_error
    expect(reasons).to eq([:manual])
  end

  describe "#generation" do
    it "cancels the child with the parent, keeping the parent's reason" do
      controller.generation do |gen|
        controller.cancel!(:ctrl_c)
        expect(gen).to be_cancelled
        expect(gen.reason).to eq(:ctrl_c)
      end
    end

    it "gives a cancelled child when the parent is cancelled already" do
      controller.cancel!(:manual)

      controller.generation { |gen| expect(gen).to be_cancelled }
    end

    it "cancels only the child with #cancel_generation!, with its detail" do
      controller.generation do |gen|
        expect(controller.cancel_generation!(:hook, { by: "loop-guard", reason: "loops" })).to be(true)
        expect(controller.cancel_generation!(:hook)).to be(false)
        expect(gen).to be_cancelled
        expect(gen.reason).to eq(:hook)
        expect(gen.detail).to eq({ by: "loop-guard", reason: "loops" })
        expect(controller).not_to be_cancelled
      end
    end

    it "is false without a running generation, and after the turn's cancel" do
      expect(controller.cancel_generation!(:hook)).to be(false)
      controller.generation { |_gen| nil }
      expect(controller.cancel_generation!(:hook)).to be(false)

      controller.generation do |_gen|
        controller.cancel!(:manual)
        expect(controller.cancel_generation!(:hook)).to be(false)
      end
    end

    it "leaves an old child alone when the parent is cancelled after its block" do
      old = nil
      controller.generation { |gen| old = gen }
      reasons = []
      old.on_cancel { |reason| reasons << reason }

      controller.cancel!(:manual)

      expect(old).not_to be_cancelled
      expect(reasons).to be_empty
    end
  end

  it "names who stopped it only when a hook did and said so" do
    expect(described_class.new.tap { |c| c.cancel!(:hook, { by: "loop-guard", reason: "loops" }) }.stopped_by).to eq("loop-guard")
    expect(described_class.new.tap { |c| c.cancel!(:hook, { reason: "loops" }) }.stopped_by).to be_nil
    expect(described_class.new.tap { |c| c.cancel!(:user, { by: "x" }) }.stopped_by).to be_nil
    expect(described_class.new.stopped_by).to be_nil
  end

  it "is still reachable as Client::CancellationController" do
    expect(Samagotchi::Client::CancellationController).to be(described_class)
  end
end
