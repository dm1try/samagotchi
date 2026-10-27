# frozen_string_literal: true

require "samagotchi/participant_mode"

RSpec.describe Samagotchi::ParticipantMode do
  it "resolves every session to review in P0" do
    [nil, Object.new].each { |session| expect(described_class.of(session)).to eq(:review) }
  end
end
