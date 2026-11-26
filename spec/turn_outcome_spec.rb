# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/turn_outcome"
require "samagotchi/last_turn"
require "samagotchi/session"

RSpec.describe Samagotchi::TurnOutcome do
  def turn(outcome, **fields) = Samagotchi::LastTurn.new(outcome: outcome, enqueued_id: "t1", **fields)

  describe "#detail" do
    it "is nil before the turn settles" do
      outcome = described_class.new(replied: false, turn: nil)

      expect(outcome).not_to be_settled
      expect(outcome.detail).to be_nil
    end

    it "says turn completed for a reply or a completed turn" do
      expect(described_class.new(replied: true, turn: nil).detail).to eq("turn completed")
      expect(described_class.new(replied: false, turn: turn("completed")).detail).to eq("turn completed")
    end

    it "names an unfinished turn's outcome, error kind, cancel reason and stopper" do
      failed = turn("canceled", cancel_reason: "user", stopped_by: "web")

      expect(described_class.new(replied: false, turn: failed).detail).to eq("turn canceled: user: web")
      expect(described_class.new(replied: false, turn: turn("error", error_kind: "timeout")).detail)
        .to eq("turn error: timeout")
    end

    # A schedule's last result for a turn chi itself failed (TurnEndings::CHI_ERROR).
    it "names chi's own failure by its kind" do
      expect(described_class.new(replied: false, turn: turn("failed", error_kind: "chi_error")).detail)
        .to eq("turn failed: chi_error")
    end

    it "says the turn did not complete when it names no reason" do
      expect(described_class.new(replied: false, turn: turn(nil)).detail).to eq("turn did not complete")
    end
  end

  it "counts only the turn as completed, never the reply" do
    expect(described_class.new(replied: true, turn: nil)).not_to be_completed
    expect(described_class.new(replied: true, turn: nil)).to be_settled
    expect(described_class.new(replied: false, turn: turn("completed"))).to be_completed
  end

  describe ".for" do
    around { |example| Dir.mktmpdir("turn-outcome-spec") { |dir| @dir = dir and example.run } }

    let(:session_dir) { File.join(@dir, "sid").tap { |dir| FileUtils.mkdir_p(dir) } }

    it "reads the session's last turn when it is that turn, and the reply file" do
      session = instance_double(Samagotchi::Session, last_turn: turn("completed"))
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::OUTPUT_DIR))
      File.write(File.join(session_dir, Samagotchi::SessionInbox::OUTPUT_DIR, "001-t1.txt"), "done")

      outcome = described_class.for(session, "t1", session_dir: session_dir)

      expect(outcome).to have_attributes(replied: true, turn: turn("completed"))
    end

    it "is unsettled when the last turn is another one and nothing was settled or replied" do
      session = instance_double(Samagotchi::Session, last_turn: turn("completed").with(enqueued_id: "t0"))

      expect(described_class.for(session, "t1", session_dir: session_dir)).not_to be_settled
    end
  end
end
