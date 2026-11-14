# frozen_string_literal: true

require "samagotchi/session_participants"

RSpec.describe Samagotchi::SessionParticipants do
  it "tells the time it measures \"active\" at, its clock's (the Engine hands it to GuardrailWiring)" do
    at = Time.utc(2026, 11, 14, 12)
    expect(described_class.new(state_dir: -> { "/tmp" }, clock: -> { at }).now).to eq(at)
  end
end
