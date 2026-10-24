# frozen_string_literal: true

require "samagotchi/last_turn"

# How a session's last turn ended (Session#last_turn), as session.json
# saves it.
RSpec.describe Samagotchi::LastTurn do
  let(:failed) do
    { "outcome" => "failed", "ended_at" => "2026-10-04T10:00:00.000+00:00", "seconds" => 2.5, "origin" => "client",
      "error_kind" => "credits", "retryable" => false, "kept_steps" => 2 }
  end

  it "reads a saved record and writes it back the same: string keys, in order, unset fields left out" do
    turn = described_class.from_file(failed)
    expect(turn).to have_attributes(outcome: "failed", seconds: 2.5, error_kind: "credits", retryable: false,
                                    exhausted: nil, stopped_by: nil)
    expect(turn.to_file.to_a).to eq(failed.to_a)
  end

  it "reads symbol keys, keeps a LastTurn as it is, and is nil for anything but a Hash" do
    turn = described_class.from_file({ outcome: "canceled", stopped_by: "loop-guard" })
    expect(turn).to eq(described_class.new(outcome: "canceled", stopped_by: "loop-guard"))
    expect(described_class.from_file(turn)).to be(turn)
    expect(described_class.from_file(nil)).to be_nil
    expect(described_class.from_file("completed")).to be_nil
  end

  it "round-trips a turn's enqueued_id, and a newer file's unknown key is dropped" do
    turn = described_class.from_file({ "outcome" => "completed", "enqueued_id" => "q1", "from_the_future" => 1 })
    expect(turn.enqueued_id).to eq("q1")
    expect(turn.to_file).to eq("outcome" => "completed", "enqueued_id" => "q1")
    expect(turn.stop_facts).to eq({})
  end

  it "gives the stop facts it has, by Result's names (false kept)" do
    expect(described_class.from_file(failed).stop_facts).to eq(error_kind: "credits", retryable: false, kept_steps: 2)
    expect(described_class.new(outcome: "completed").stop_facts).to eq({})
    expect(described_class::STOP_FACTS).to all(satisfy { |fact| described_class.members.include?(fact) })
  end

  it "names a participant's turn by its author (participant_author), nobody for the owner's" do
    expect(described_class.new(outcome: "completed", author: "p:p_1").participant_author).to eq("p:p_1")
    expect(described_class.new(outcome: "completed").participant_author).to be_nil
    expect(described_class.new(outcome: "completed", author: "owner").participant_author).to be_nil
  end
end
