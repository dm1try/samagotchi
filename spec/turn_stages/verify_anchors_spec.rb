# frozen_string_literal: true

require "tmpdir"
require "samagotchi/turn_stages/verify_anchors"

# The stage has no state of its own: each call reads only the turn and the
# messages it is given (the engine specs cover Verify and Revise turns).
RSpec.describe Samagotchi::TurnStages::VerifyAnchors do
  let(:stage) { described_class.new(state_dir: -> { Dir.tmpdir }) }
  let(:turn) { Struct.new(:id, :verify, :revises).new("t1", nil, nil) }

  it "keeps nothing of a turn it stamped" do
    messages = [{ role: "user", content: "hi", turn_id: "t1" }]

    expect(stage.stamp_opening(messages, turn, "completed")).to be_nil
    expect(stage.record_verdict(turn, "completed")).to be_nil
    expect(stage.verified(nil, nil)).to be_nil
    expect(messages.first.keys).to eq(%i[role content turn_id])
    expect(stage.instance_variables).to eq([:@state_dir])
  end
end
