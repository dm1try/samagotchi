# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/turn_stages/verify_anchors"

# The stage has no state of its own: each call reads only the turn and the
# messages it is given, and the sessions dir when it is called (the engine
# specs cover Verify and Revise turns).
RSpec.describe Samagotchi::TurnStages::VerifyAnchors do
  let(:dir) { Dir.mktmpdir("verify-anchors") }
  let(:state_dir) { [File.join(dir, "elsewhere")] }
  let(:stage) { described_class.new(state_dir: -> { state_dir.first }) }
  let(:turn) { Struct.new(:id, :verify, :revises).new("t1", nil, nil) }

  after { FileUtils.rm_rf(dir) }

  it "keeps nothing of a turn it stamped" do
    messages = [{ role: "user", content: "hi", turn_id: "t1" }]

    expect(stage.stamp_opening(messages, turn, "completed")).to be_nil
    expect(stage.record_verdict(turn, "completed")).to be_nil
    expect(stage.verified(nil, nil)).to be_nil
    expect(messages.first.keys).to eq(%i[role content turn_id])
    expect(stage.instance_variables).to eq([:@state_dir])
  end

  it "checks a fresh child's claim in its parent, loaded from the sessions dir it reads at the call" do
    sessions = File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) }
    parent = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap do |s|
      s.messages = [{ role: "user", content: "check it", turn_id: "p1" }, { role: "model", content: "The build is green." }]
      s.save(state_dir: sessions)
    end
    anchor = Samagotchi::VerifyAnchor.new(turn_id: "p1", quote: "build is green")
    child = Struct.new(:verify_fresh, :parent_id).new(Struct.new(:anchor).new(anchor), parent.id)
    allow(Samagotchi::Log).to receive(:warn)

    # Built while the dir was elsewhere: the parent isn't found there.
    expect(stage.verified(child, anchor)).to be_nil
    expect(Samagotchi::Log).to have_received(:warn).with(:turn, "verify_anchor_rejected", hash_including(reason: :source_session_unavailable))

    state_dir[0] = sessions
    expect(stage.verified(child, anchor)).to eq(anchor)
    expect(stage.verified(child, Samagotchi::VerifyAnchor.new(turn_id: "p1", quote: "build is red"))).to be_nil
  end
end
