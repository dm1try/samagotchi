# frozen_string_literal: true

require "samagotchi/turn_preamble"

RSpec.describe Samagotchi::TurnPreamble do
  subject(:turn_preamble) { described_class.new }

  describe "#phrase" do
    it "returns nil when nothing has been fed" do
      expect(turn_preamble.phrase).to be_nil
    end

    it "extracts a TURN: line fed as a single complete chunk" do
      turn_preamble.feed("TURN: reading project config\nmore reasoning here")
      expect(turn_preamble.phrase).to eq("reading project config")
    end

    it "extracts a TURN: line fed across multiple chunks" do
      turn_preamble.feed("TURN: reading ")
      turn_preamble.feed("project config\n")
      turn_preamble.feed("continuing to reason")
      expect(turn_preamble.phrase).to eq("reading project config")
    end

    it "is case-insensitive on the TURN: marker" do
      turn_preamble.feed("turn: checking the tests\n")
      expect(turn_preamble.phrase).to eq("checking the tests")
    end

    it "caches the first TURN: line and ignores later TURN:-like text" do
      turn_preamble.feed("TURN: first action\n")
      turn_preamble.feed("TURN: second action\n")
      expect(turn_preamble.phrase).to eq("first action")
    end

    it "truncates an overly long TURN: phrase" do
      long_phrase = "a" * 200
      turn_preamble.feed("TURN: #{long_phrase}\n")
      expect(turn_preamble.phrase.length).to eq(described_class::MAX_PHRASE_LENGTH)
    end

    it "falls back to the first sentence when no TURN: line is present" do
      turn_preamble.feed("I should look at the config file first. Then check the tests.")
      expect(turn_preamble.phrase).to eq("I should look at the config file first.")
    end

    it "falls back to the full buffer when no sentence terminator has streamed yet" do
      turn_preamble.feed("still thinking without punctuation")
      expect(turn_preamble.phrase).to eq("still thinking without punctuation")
    end

    it "caps an overly long fallback sentence at the display-safe length" do
      turn_preamble.feed("a" * 200)
      expect(turn_preamble.phrase.length).to eq(described_class::MAX_PHRASE_LENGTH)
    end

    it "ignores nil or empty feeds" do
      turn_preamble.feed(nil)
      turn_preamble.feed("")
      expect(turn_preamble.phrase).to be_nil
    end
  end
end
