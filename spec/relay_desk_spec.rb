# frozen_string_literal: true

require "spec_helper"
require "samagotchi/relay_desk"

RSpec.describe Samagotchi::RelayDesk do
  let(:now) { [1000.0] }
  let(:desk) { described_class.new(clock: -> { now[0] }) }

  it "opens a relay under a fresh id, open until its answer is recorded" do
    id = desk.open(child_id: "c-1", child_question_id: "q-1")
    expect(id).to match(/\A\h{8}-\h{4}-/)
    expect(desk.status(id)).to eq(child_id: "c-1", child_question_id: "q-1", state: "open", answer: nil, by: nil)

    desk.record(id, selected_indices: [0], freeform: nil, dismissed: false, by: "user")
    expect(desk.status(id)).to eq(child_id: "c-1", child_question_id: "q-1", state: "answered",
                                  answer: { selected_indices: [0], freeform: nil, dismissed: false }, by: "user")
  end

  it "records only the first answer, and nothing on a closed relay" do
    id = desk.open(child_id: "c", child_question_id: "q")
    expect(desk.record(id, selected_indices: [1], by: "user")).to be(true)
    expect(desk.record(id, selected_indices: [0], by: "user")).to be(false)
    expect(desk.status(id)[:answer][:selected_indices]).to eq([1])

    other = desk.open(child_id: "c", child_question_id: "q2")
    desk.close(other)
    expect(desk.record(other, selected_indices: [0], by: "user")).to be(false)
    expect(desk.status(other)[:state]).to eq("closed")
  end

  it "forgets a relay 10 minutes after it settled, never an open one; nil for an unknown id" do
    open_id = desk.open(child_id: "c", child_question_id: "q")
    done = desk.open(child_id: "c", child_question_id: "q2")
    desk.record(done, selected_indices: [0], by: "user")
    now[0] += described_class::KEEP_SECONDS + 1

    expect(desk.status(done)).to be_nil
    expect(desk.status(open_id)[:state]).to eq("open")
    expect(desk.status("nope")).to be_nil
  end

  it "is active while a relay is open or settled less than 10 minutes ago (a restart would drop it)" do
    expect(desk).not_to be_active
    id = desk.open(child_id: "c", child_question_id: "q")
    expect(desk).to be_active
    desk.close(id)
    now[0] += 599
    expect(desk).to be_active
    now[0] += 2
    expect(desk).not_to be_active
  end
end
