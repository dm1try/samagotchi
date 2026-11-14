# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/turn_stages/verify_anchors"
require "samagotchi/turn_origin"

# The stage has no state of its own: each call reads only the turn and the
# messages it is given, and the sessions dir it is given (the engine specs
# cover Verify and Revise turns).
RSpec.describe Samagotchi::TurnStages::VerifyAnchors do
  let(:dir) { Dir.mktmpdir("verify-anchors") }
  let(:stage) { described_class.new }
  let(:turn) { Struct.new(:id, :verify, :revises).new("t1", nil, nil) }

  after { FileUtils.rm_rf(dir) }

  it "keeps nothing of a turn it stamped" do
    messages = [{ role: "user", content: "hi", turn_id: "t1" }]

    expect(stage.stamp_opening(messages, turn, "completed")).to be_nil
    expect(stage.record_verdict(turn, "completed")).to be_nil
    expect(stage.verified(nil, nil, state_dir: dir)).to be_nil
    expect(messages.first.keys).to eq(%i[role content turn_id])
    expect(stage.instance_variables).to eq([])
  end

  it "checks a fresh child's claim in its parent, loaded from the sessions dir it is given" do
    sessions = File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) }
    parent = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap do |s|
      s.messages = [{ role: "user", content: "check it", turn_id: "p1" }, { role: "model", content: "The build is green." }]
      s.save(state_dir: sessions)
    end
    anchor = Samagotchi::VerifyAnchor.new(turn_id: "p1", quote: "build is green")
    child = Struct.new(:verify_fresh, :parent_id).new(Struct.new(:anchor).new(anchor), parent.id)
    allow(Samagotchi::Log).to receive(:warn)

    # Another dir: the parent isn't found there.
    expect(stage.verified(child, anchor, state_dir: File.join(dir, "elsewhere"))).to be_nil
    expect(Samagotchi::Log).to have_received(:warn).with(:turn, "verify_anchor_rejected", hash_including(reason: :source_session_unavailable))

    expect(stage.verified(child, anchor, state_dir: sessions)).to eq(anchor)
    expect(stage.verified(child, Samagotchi::VerifyAnchor.new(turn_id: "p1", quote: "build is red"), state_dir: sessions)).to be_nil
  end

  describe "a participant's Revise at the stamp (ParticipantRevise)" do
    let(:alex) { "p:alex" }
    let(:v1) { "123e4567-e89b-12d3-a456-426614174001" }

    def revise_turn(author)
      origin = Samagotchi::TurnOrigin.new(client_id: author ? "review:x" : "web:o", author: author)
      Struct.new(:id, :verify, :revises, :origin).new("r1", nil, Samagotchi::ReviseAnchor.new(turn_id: v1), origin)
    end

    def messages(target_author, *between)
      [{ role: "user", content: "q", turn_id: v1, **(target_author ? { author: target_author } : {}) },
       { role: "assistant", content: "long" }, *between,
       { role: "user", content: "shorter", turn_id: "r1", **(target_author == alex ? { author: alex } : {}) },
       { role: "assistant", content: "short" }]
    end

    before { allow(Samagotchi::Log).to receive(:warn) }

    it "stamps their Revise of their own turn" do
      list = messages(alex)
      expect(stage.stamp_opening(list, revise_turn(alex), "completed")).to eq(Samagotchi::ReviseAnchor.new(turn_id: v1))
      expect(list[2][:revises]).to eq(turn_id: v1)
    end

    it "doesn't stamp one over the owner's turn (logged, not_own)" do
      list = messages(nil)
      list[2][:author] = alex
      expect(stage.stamp_opening(list, revise_turn(alex), "completed")).to be_nil
      expect(list[2]).not_to have_key(:revises)
      expect(Samagotchi::Log).to have_received(:warn).with(:turn, "revise_anchor_rejected", turn_id: v1, reason: :not_own)
    end

    it "doesn't stamp one someone else's turn overtook (logged, overtaken): a plain turn" do
      list = messages(alex, { role: "user", content: "mine", turn_id: "o1" }, { role: "assistant", content: "ok" })
      expect(stage.stamp_opening(list, revise_turn(alex), "completed")).to be_nil
      expect(list[4]).not_to have_key(:revises)
      expect(Samagotchi::Log).to have_received(:warn).with(:turn, "revise_anchor_rejected", turn_id: v1, reason: :overtaken)
    end

    it "re-targets their stale draft at v1 to their own v2, the stack's top" do
      v2 = "123e4567-e89b-12d3-a456-426614174002"
      list = messages(alex)
      list.insert(2, { role: "user", content: "cut it", turn_id: v2, author: alex, revises: { turn_id: v1 } },
                  { role: "assistant", content: "cut" })
      expect(stage.stamp_opening(list, revise_turn(alex), "completed")).to eq(Samagotchi::ReviseAnchor.new(turn_id: v2))
      expect(list[4][:revises]).to eq(turn_id: v2)
    end

    it "refuses their Revise of their own Verify turn (sent while it ran, before the page knew): not_own, no stamp" do
      list = messages(alex)
      list[0][:verify] = { turn_id: "123e4567-e89b-12d3-a456-426614174009", quote: "the claim" }
      expect(stage.stamp_opening(list, revise_turn(alex), "completed")).to be_nil
      expect(list[2]).not_to have_key(:revises)
      expect(Samagotchi::Log).to have_received(:warn).with(:turn, "revise_anchor_rejected", turn_id: v1, reason: :not_own)
    end

    it "still stamps the owner's Revise of a participant's turn (the owner's path is unchanged)" do
      list = messages("p:bea")
      expect(stage.stamp_opening(list, revise_turn(nil), "completed")).to eq(Samagotchi::ReviseAnchor.new(turn_id: v1))
    end
  end
end
