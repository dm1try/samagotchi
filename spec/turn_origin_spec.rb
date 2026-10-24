# frozen_string_literal: true

require "spec_helper"
require "samagotchi/turn_origin"

RSpec.describe Samagotchi::TurnOrigin do
  describe ".from" do
    it "reads a Hash with symbol keys (an event's) or string keys (a parsed line's)" do
      expected = described_class.new(client_id: "web:1", enqueued_id: "e1", author: "p:p_1")

      expect(described_class.from({ client_id: "web:1", enqueued_id: "e1", author: "p:p_1" })).to eq(expected)
      expect(described_class.from({ "client_id" => "web:1", "enqueued_id" => "e1", "author" => "p:p_1" })).to eq(expected)
    end

    it "keeps a TurnOrigin as it is" do
      origin = described_class.new(client_id: "tui:1")

      expect(described_class.from(origin)).to equal(origin)
    end

    it "is nil when nothing names a sender: nil, an empty Hash, nil fields, anything else" do
      expect(described_class.from(nil)).to be_nil
      expect(described_class.from({})).to be_nil
      expect(described_class.from({ client_id: nil, author: nil })).to be_nil
      expect(described_class.from("web:1")).to be_nil
    end
  end

  describe ".of" do
    it "is .from's origin, or NONE when nothing names a sender: in-process an origin is never nil" do
      origin = described_class.new(client_id: "web:1")

      expect(described_class.of(origin)).to equal(origin)
      expect(described_class.of({ "client_id" => "web:1" })).to eq(origin)
      [nil, {}, { author: nil }].each { |value| expect(described_class.of(value)).to equal(described_class::NONE) }
    end
  end

  describe "#empty? and #wire" do
    it "NONE names no sender: no wire form, where every other origin's is its #to_h" do
      expect(described_class::NONE).to be_empty
      expect(described_class::NONE.wire).to be_nil
      expect(described_class.new(client_id: "web:1")).not_to be_empty
      expect(described_class.new(client_id: "web:1").wire).to eq(client_id: "web:1")
    end
  end

  describe "#to_h" do
    it "is the wire Hash: only the fields set, so an origin goes out as it always did" do
      expect(described_class.new(client_id: "cli:send").to_h).to eq(client_id: "cli:send")
      expect(described_class.new(client_id: "web:1", enqueued_id: "e1", author: "p:p_1").to_h)
        .to eq(client_id: "web:1", enqueued_id: "e1", author: "p:p_1")
    end

    it "reads back as the same origin" do
      origin = described_class.new(client_id: "review:p_1", enqueued_id: "e2", author: "p:p_1")

      expect(described_class.from(origin.to_h)).to eq(origin)
      expect(described_class.from(JSON.parse(JSON.generate(origin.to_h)))).to eq(origin)
    end
  end

  describe "the author" do
    it "is a participant's for any author but none or the owner's (Steer.participant_author?)" do
      participant = described_class.new(client_id: "review:p_1", author: "p:p_1")

      expect(participant).to be_participant
      expect(participant.participant_author).to eq("p:p_1")
      expect(participant.participant_id).to eq("p_1")
    end

    it "is nobody's for the owner: no author, or the owner's" do
      [described_class.new(client_id: "web:1"), described_class.new(author: "owner"), described_class.new(author: "")].each do |origin|
        expect(origin).not_to be_participant
        expect(origin.participant_author).to be_nil
        expect(origin.participant_id).to be_nil
      end
    end
  end

  describe "the sender" do
    it "names it by its client (ClientId.origin), \"client\" for none" do
      expect(described_class.new(client_id: "child:abcd1234").source).to eq("delegate_report")
      expect(described_class.new(client_id: "system:reminder").source).to eq("reminder")
      expect(described_class::NONE.source).to eq("client")
    end

    it "is a human's for typed input and for no client (ClientId.human?), not for chi's own" do
      expect(described_class.new(client_id: "web:1")).to be_human
      expect(described_class::NONE).to be_human
      expect(described_class.new(client_id: "task:t1")).not_to be_human
    end
  end
end
