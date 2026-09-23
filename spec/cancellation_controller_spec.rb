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
    expect(calls).to eq([[:kept, :user]])
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

  it "is still reachable as Client::CancellationController" do
    expect(Samagotchi::Client::CancellationController).to be(described_class)
  end
end
