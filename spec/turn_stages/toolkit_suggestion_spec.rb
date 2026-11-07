# frozen_string_literal: true

require "tmpdir"
require "samagotchi/turn_stages/toolkit_suggestion"

# The stage keeps one turn's Pending, keyed on that very Turn, and lets it
# go once the turn's suggestion is done.
RSpec.describe Samagotchi::TurnStages::ToolkitSuggestion do
  let(:stage) do
    described_class.new(side_judgments: Samagotchi::SideJudgments.new, host_registry: nil, toolkit_binding: nil,
                        tools: nil, state_dir: -> { Dir.tmpdir }, recording: ->(client, *, **) { client }, runs: -> {})
  end

  let(:pending) { instance_double(Samagotchi::ToolkitSuggest::Pending, abandon: nil) }
  let(:t1) { Object.new }
  let(:t2) { Object.new }

  # The ask itself (eligibility, the snapshot, the thread) is the engine
  # specs'; here only which turn a Pending belongs to.
  before { allow(stage).to receive(:ask).and_return(pending) }

  it "leaves a turn's Pending alone when another turn abandons" do
    stage.start(t1)

    stage.abandon(t2, :failed)
    stage.finish(t2)

    expect(pending).not_to have_received(:abandon)
    stage.abandon(t1, :canceled)
    expect(pending).to have_received(:abandon).with(:canceled).once
  end

  it "holds nothing of a turn once it is finished" do
    stage.start(t1)
    stage.finish(t1)

    expect(stage.instance_variables.map { |name| stage.instance_variable_get(name) })
      .not_to include(satisfy { |value| value.equal?(t1) || value.equal?(pending) })
    stage.abandon(t1, :failed)
    expect(pending).not_to have_received(:abandon)
  end
end
