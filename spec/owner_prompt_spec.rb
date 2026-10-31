# frozen_string_literal: true

require "spec_helper"
require "samagotchi/owner_prompt"

RSpec.describe Samagotchi::OwnerPrompt do
  describe ".message?" do
    it "counts the Engine's prompt line and TurnCheckpoint's stamped one" do
      expect(described_class.message?({ role: "user", turn_id: "t1", content: "go" })).to be(true)
      expect(described_class.message?({ "role" => "user", "turn_id" => "t1", "content" => "go" })).to be(true)
      expect(described_class.message?({ role: "user", content: "go", at: "2026-10-27T10:00:00.000+00:00" }))
        .to be(true)
    end

    it "doesn't count a !command's output, a declined continue's reason or the Qwen recovery prompt" do
      expect(described_class.message?({ role: "user", content: "!(ls)\na b" })).to be(false)
      expect(described_class.message?({ role: "user", content: "The user chose not to continue: …" })).to be(false)
      expect(described_class.message?({ role: "user", content: "Finish the call", preserve_literals: true }))
        .to be(false)
    end

    it "doesn't count a participant's line, a steer, a note or a reminder" do
      expect(described_class.message?({ role: "user", turn_id: "t1", content: "go", author: "p_1" })).to be(false)
      expect(described_class.message?({ role: "user", turn_id: "t1", content: "go", author: "owner" })).to be(true)
      %w[input steer note reminder].each do |kind|
        expect(described_class.message?({ role: "user", turn_id: "t1", content: "go", kind: kind })).to be(false)
      end
    end
  end

  describe ".turn?" do
    let(:session) { Struct.new(:review?).new(false) }

    it "is the owner's turn in a working session" do
      expect(described_class.turn?(session: session, author: nil)).to be(true)
      expect(described_class.turn?(session: session, author: "owner")).to be(true)
    end

    it "isn't a participant's turn, nor any turn in a review session" do
      expect(described_class.turn?(session: session, author: "p_1")).to be(false)
      expect(described_class.turn?(session: Struct.new(:review?).new(true), author: nil)).to be(false)
    end
  end
end
