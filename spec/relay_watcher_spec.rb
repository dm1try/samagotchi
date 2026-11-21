# frozen_string_literal: true

require "spec_helper"
require "samagotchi/relay_watcher"
require "samagotchi/pending_question"
require "samagotchi/question_desk"

RSpec.describe Samagotchi::RelayWatcher do
  let(:pending) { [Samagotchi::PendingQuestion.new(id: "q1", relayed_to: { relay_id: "r1" })] }
  let(:desk) { instance_double(Samagotchi::QuestionDesk, pending: nil) }

  before do
    allow(desk).to receive(:pending) { pending[0] }
    allow(desk).to receive(:annotate) do |_id, relayed_to:, reason:|
      pending[0] = pending[0].with(relayed_to: nil) if relayed_to.nil?
      true
    end
  end

  def start(live) = described_class.start(question_desk: desk, question_id: "q1", relay_id: "r1", parent_dir: "/x", interval: 0.02, live: live)

  it "clears the relay mark once the parent's worker is gone, then stops" do
    up = [true]
    checks = 0
    thread = start(-> { checks += 1; up[0] })
    wait_for("three checks of the live parent") { checks >= 3 }
    expect(desk).not_to have_received(:annotate)

    up[0] = false
    join!(thread, "the relay watcher")
    expect(thread).not_to be_alive
    expect(desk).to have_received(:annotate).with("q1", relayed_to: nil, reason: "parent_gone").once
  end

  it "stops without touching anything once the question is answered or another relay's" do
    thread = start(-> { true })
    pending[0] = Samagotchi::PendingQuestion.new(id: "q1", relayed_to: { relay_id: "r2" })
    join!(thread, "the relay watcher")
    expect(thread).not_to be_alive

    pending[0] = nil
    thread = start(-> { false })
    join!(thread, "the relay watcher")
    expect(thread).not_to be_alive
    expect(desk).not_to have_received(:annotate)
  end
end
