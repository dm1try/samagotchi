# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/participant_exposure"

# The exposure policy: a grant's level → the usage fields a participant's
# review data shows (the review-composer plan's D3). One level today, own.
RSpec.describe Samagotchi::Web::ParticipantExposure do
  let(:sources) do
    { spent: -> { 0.5 }, cap: -> { 2.0 }, queued: -> { 1 }, queue_limit: -> { 3 },
      expires_at: -> { "2026-11-02T10:00:00Z" }, model: -> { "m" } }
  end

  it "shows own's fields: the participant's spend and cap, queue, link expiry and the model" do
    expect(described_class.usage("own", sources))
      .to eq(spent: 0.5, cap: 2.0, queued: 1, queue_limit: 3, expires_at: "2026-11-02T10:00:00Z", model: "m")
  end

  it "is own by default" do
    expect(described_class::DEFAULT).to eq("own")
  end

  it "reads a level it doesn't know (a newer chi's, a hand edit) as the default, never more" do
    [nil, "session", "", { "plan" => true }, 3].each do |value|
      expect(described_class.level(value)).to eq("own"), value.inspect
      expect(described_class.fields(value)).to eq(described_class::LEVELS.fetch("own"))
    end
  end

  it "computes only the fields a level shows" do
    called = []
    lazy = sources.to_h do |field, source|
      [field, lambda do
        called << field
        source.call
      end]
    end
    lazy[:session_spent] = -> { raise "not shown at own" }
    described_class.usage("own", lazy)
    expect(called).to eq(described_class::LEVELS.fetch("own"))
  end

  it "refuses a field a level names with no source, rather than leave it out" do
    expect { described_class.usage("own", sources.except(:model)) }.to raise_error(KeyError)
  end
end
