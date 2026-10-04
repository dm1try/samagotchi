# frozen_string_literal: true

require "spec_helper"
require "samagotchi/relay_watcher"

RSpec.describe Samagotchi::RelayWatcher do
  let(:pending) { [{ id: "q1", relayed_to: { relay_id: "r1" } }] }
  let(:engine) { double("engine", pending_question: nil) }

  before do
    allow(engine).to receive(:pending_question) { pending[0] }
    allow(engine).to receive(:annotate_question) do |_id, relayed_to:, reason:|
      pending[0] = pending[0].except(:relayed_to) if relayed_to.nil?
      true
    end
  end

  def start(live) = described_class.start(engine: engine, question_id: "q1", relay_id: "r1", parent_dir: "/x", interval: 0.02, live: live)

  it "clears the relay mark once the parent's worker is gone, then stops" do
    up = [true]
    thread = start(-> { up[0] })
    sleep(0.08)
    expect(engine).not_to have_received(:annotate_question)

    up[0] = false
    thread.join(1)
    expect(thread).not_to be_alive
    expect(engine).to have_received(:annotate_question).with("q1", relayed_to: nil, reason: "parent_gone").once
  end

  it "stops without touching anything once the question is answered or another relay's" do
    thread = start(-> { true })
    pending[0] = { id: "q1", relayed_to: { relay_id: "r2" } }
    thread.join(1)
    expect(thread).not_to be_alive

    pending[0] = nil
    thread = start(-> { false })
    thread.join(1)
    expect(thread).not_to be_alive
    expect(engine).not_to have_received(:annotate_question)
  end
end
