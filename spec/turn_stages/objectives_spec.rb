# frozen_string_literal: true

require "samagotchi/side_judgments"
require "samagotchi/turn_stages/objectives"

# The stage keeps a turn's proposals until that turn is over, then gives
# their cards (a completed turn) or drops them (any other ending): none
# outlives the turn. The announced view is the last one's: the event only
# when it changed.
RSpec.describe Samagotchi::TurnStages::Objectives do
  let(:cards) { [] }
  let(:stage) { described_class.new(side_judgments: Samagotchi::SideJudgments.new, host_registry: nil) }

  def proposal(id) = Samagotchi::Objectives::Proposal.new(change: "done", id: id, text: "", note: "n")
  def turn(outcome) = Struct.new(:outcome) { def completed? = outcome == "completed" }.new(outcome)

  it "shows a completed turn's proposals once and keeps none after" do
    stage.propose(proposal("O1"))
    stage.propose(proposal("O1"))

    cards.concat(stage.finally(turn("completed")))
    cards.concat(stage.finally(turn("completed")))

    expect(cards.size).to eq(1)
    expect(cards.first).to include(source: Samagotchi::Objectives::SOURCE, id: start_with("objectives-"))
    expect(stage.proposals).to be_empty
  end

  it "drops another ending's proposals without a card, so the next turn shows none" do
    stage.propose(proposal("O1"))

    cards.concat(stage.finally(turn("canceled")))
    cards.concat(stage.finally(turn("completed")))

    expect(cards).to be_empty
    expect(stage.proposals).to be_empty
  end

  it "refuses past the per-turn limit, and takes them again once the turn is over" do
    answers = (1..(Samagotchi::Objectives::PROPOSALS_PER_TURN + 1)).map { |n| stage.propose(proposal("O#{n}")) }
    expect(answers.last).to be(false)

    stage.finally(turn("failed"))
    expect(stage.propose(proposal("O9"))).to be(true)
  end

  it "gives the view's event only when it changed, and keeps the last one" do
    session = Struct.new(:id, :messages).new("s1", [])
    view = { items: [{ id: "O1" }] }
    changed_view = { items: [] }

    expect(stage.announce(session, view: view)).to eq(type: :objectives_updated, session_id: "s1", **view)
    expect(stage.announce(session, view: view)).to be_nil
    expect(stage.announce(session, view: changed_view)).to include(items: [])
  end
end
