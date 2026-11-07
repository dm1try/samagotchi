# frozen_string_literal: true

require "tmpdir"
require "samagotchi/side_judgments"
require "samagotchi/turn_stages/objectives"

# The stage keeps a turn's proposals until that turn is over, then shows
# them (a completed turn) or drops them (any other ending): none outlives
# the turn.
RSpec.describe Samagotchi::TurnStages::Objectives do
  let(:cards) { [] }
  let(:stage) do
    described_class.new(side_judgments: Samagotchi::SideJudgments.new, host_registry: nil, state_dir: -> { Dir.tmpdir },
                        recording: ->(client, *, **) { client }, runs: -> {}, synchronize: ->(&block) { block.call },
                        announce: ->(_event) {}, running: -> {}, show_card: ->(**card) { cards << card })
  end

  def proposal(id) = Samagotchi::Objectives::Proposal.new(change: "done", id: id, text: "", note: "n")
  def turn(outcome) = Struct.new(:outcome) { def completed? = outcome == "completed" }.new(outcome)

  it "shows a completed turn's proposals once and keeps none after" do
    stage.propose(proposal("O1"))
    stage.propose(proposal("O1"))

    stage.finally(turn("completed"))
    stage.finally(turn("completed"))

    expect(cards.size).to eq(1)
    expect(stage.proposals).to be_empty
  end

  it "drops another ending's proposals without a card, so the next turn shows none" do
    stage.propose(proposal("O1"))

    stage.finally(turn("canceled"))
    stage.finally(turn("completed"))

    expect(cards).to be_empty
    expect(stage.proposals).to be_empty
  end

  it "refuses past the per-turn limit, and takes them again once the turn is over" do
    answers = (1..(Samagotchi::Objectives::PROPOSALS_PER_TURN + 1)).map { |n| stage.propose(proposal("O#{n}")) }
    expect(answers.last).to be(false)

    stage.finally(turn("failed"))
    expect(stage.propose(proposal("O9"))).to be(true)
  end
end
