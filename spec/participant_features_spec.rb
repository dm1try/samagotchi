# frozen_string_literal: true

require "samagotchi/delivery"
require "samagotchi/bridge"

# The participant features a worker advertises (Bridge::FEATURES): an older
# chi web sends no participant's turn to a worker without review_turns, and
# this chi none to one without pair_turns (Delivery::PAIR_UNAVAILABLE), so
# both stay on the wire.
RSpec.describe "a worker's participant features" do
  it "names both review_turns and pair_turns" do
    expect([Samagotchi::Delivery::REVIEW_FEATURE, Samagotchi::Delivery::PAIR_FEATURE]).to eq(%w[review_turns pair_turns])
    expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::PAIR_FEATURE, Samagotchi::Delivery::REVIEW_FEATURE)
  end
end
