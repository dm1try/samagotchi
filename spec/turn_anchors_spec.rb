# frozen_string_literal: true

require "spec_helper"
require "samagotchi/turn_anchors"

RSpec.describe Samagotchi::TurnAnchors do
  let(:v1) { "123e4567-e89b-12d3-a456-426614174000" }
  let(:verify) { { "turn_id" => v1, "quote" => "the claim" } }

  describe Samagotchi::ReviseAnchor do
    it "takes a turn id (UUID-checked), string or symbol keys, and nothing else" do
      expect(described_class.from("turn_id" => v1)).to eq(described_class.new(turn_id: v1))
      expect(described_class.from(turn_id: v1).to_file).to eq("turn_id" => v1)
      [nil, "x", { turn_id: "v1" }, { turn_id: v1, quote: "q" }, { turn_id: 1 }, {}].each do |value|
        expect(described_class.from(value)).to be_nil, value.inspect
      end
    end
  end

  it "reads each anchor from its own key of a body or an input file, dropping a malformed one" do
    anchors = described_class.from("verify" => verify, "revises" => { "turn_id" => "bad" }, "prompt" => "x")

    expect(anchors.verify).to eq(Samagotchi::VerifyAnchor.from(verify))
    expect(anchors.revises).to be_nil
    expect(anchors.to_file).to eq("verify" => verify)
    expect(described_class.from(nil)).to be_empty
  end

  it "gives each layer its shape: the wire keys, the restore event's fields, run_turn's keywords" do
    anchors = described_class.new(verify: verify, revises: { turn_id: v1 })

    expect(anchors.to_file).to eq("verify" => verify, "revises" => { "turn_id" => v1 })
    expect(anchors.to_h).to eq(verify: { turn_id: v1, quote: "the claim" }, revises: { turn_id: v1 })
    expect(anchors.participant_view).to eq("verify" => verify, "revises" => { "turn_id" => v1 })
    expect(anchors.kwargs).to eq(verify: anchors.verify, revises: anchors.revises)
    expect(anchors.present.map { |anchor| anchor.class::FEATURE }).to eq(%w[verify revise])
  end

  it "has one rule per member, in the members' order; verify and revises are held and shown" do
    expect(described_class::RULES.keys).to eq(described_class.members)
    expect(described_class::RULES.values_at(:verify, :revises))
      .to all(have_attributes(holds: true, participant: true, turn_route: true, vouched: false))
  end

  describe "reply_for (an ask's ReplyFor)" do
    let(:voice) { { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false } }

    it "is held for the turn's end, never shown to a participant, set by the ask alone, and vouched for" do
      expect(described_class::RULES[:reply_for]).to have_attributes(holds: true, participant: false, turn_route: false,
                                                                    vouched: true)
    end

    it "rides the body and the input file by its own key, the restore event and run_turn's keywords" do
      anchors = described_class.from("reply_for" => voice, "prompt" => "x")

      expect(anchors.reply_for).to eq(Samagotchi::ReplyFor.from(voice))
      expect(anchors.to_file).to eq("reply_for" => voice)
      expect(anchors.to_h).to eq(reply_for: voice)
      expect(anchors.kwargs).to eq(reply_for: anchors.reply_for)
      expect(anchors.present.map { |anchor| anchor.class::FEATURE }).to eq(%w[reply_for])
      expect(anchors.vouched).to eq([anchors.reply_for])
      expect(anchors.participant_view).to eq({})
      expect(described_class.named_in?("reply_for" => voice)).to be(true)
    end

    it "drops a malformed or full one (full is no value: the bytes of no ask)" do
      expect(described_class.from("reply_for" => { "formatting" => "rtf" })).to be_empty
      expect(described_class.from("reply_for" => "voice")).to be_empty
      expect(described_class.from("reply_for" => { "detail" => true })).to be_empty
    end

    it "is not taken from a POST …/turn body (the composer's, a participant's): only the ask sets it" do
      anchors = described_class.from_turn_route("reply_for" => voice, "verify" => verify)

      expect(anchors.reply_for).to be_nil
      expect(anchors.verify).to eq(Samagotchi::VerifyAnchor.from(verify))
    end

    it "leaves verify and revises out of the vouched ones" do
      expect(described_class.new(verify: verify, revises: { turn_id: v1 }).vouched).to eq([])
    end
  end

  it "shows a participant only the members whose rule shows them, leaving the others out" do
    stub_const("#{described_class}::RULES", described_class::RULES.merge(
      revises: described_class::RULES[:revises].with(participant: false)
    ))
    anchors = described_class.new(verify: verify, revises: { turn_id: v1 })

    expect(anchors.participant_view).to eq("verify" => verify)
    expect(described_class.new(revises: { turn_id: v1 }).participant_view).to eq({})
  end

  it "names an anchor in an input file by a Hash under its key, well-formed or not (held for the turn's end)" do
    expect(described_class.named_in?("revises" => { "turn_id" => "bad" })).to be(true)
    expect(described_class.named_in?("verify" => "x", "prompt" => "p")).to be(false)
  end

  it "holds an input file only for a member whose rule holds it" do
    stub_const("#{described_class}::RULES", described_class::RULES.merge(
      verify: described_class::RULES[:verify].with(holds: false)
    ))

    expect(described_class.named_in?("verify" => verify)).to be(false)
    expect(described_class.named_in?("verify" => verify, "revises" => { "turn_id" => v1 })).to be(true)
  end
end
