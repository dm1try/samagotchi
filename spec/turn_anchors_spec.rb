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
    expect(anchors.kwargs).to eq(verify: anchors.verify, revises: anchors.revises)
    expect(anchors.present.map { |anchor| anchor.class::FEATURE }).to eq(%w[verify revise])
    expect(anchors.without_revises).to eq(described_class.new(verify: verify))
  end

  it "names an anchor in an input file by a Hash under its key, well-formed or not (held for the turn's end)" do
    expect(described_class.named_in?("revises" => { "turn_id" => "bad" })).to be(true)
    expect(described_class.named_in?("verify" => "x", "prompt" => "p")).to be(false)
  end
end
