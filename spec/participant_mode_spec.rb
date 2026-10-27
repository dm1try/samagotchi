# frozen_string_literal: true

require "samagotchi/participant_mode"
require "samagotchi/session"
require "samagotchi/worker_link"

RSpec.describe Samagotchi::ParticipantMode do
  let(:working) { Struct.new(:id) { def review? = false }.new("0123abcd-0000-4000-8000-000000000000") }
  let(:review) { Struct.new(:id) { def review? = true }.new("0123abcd-0000-4000-8000-000000000001") }

  it "is review for a review session and for no session, pair for a working session" do
    expect(described_class.of(review)).to eq(:review)
    expect(described_class.of(nil)).to eq(:review)
    expect(described_class.of(Object.new)).to eq(:review)
    expect(described_class.of(working)).to eq(:pair)
  end

  it "keeps a working session review on a worker without the pair_turns feature" do
    expect(Samagotchi::Delivery::PAIR_FEATURE).to eq("pair_turns")
    expect(described_class.of(working, features: %w[delivery review_turns])).to eq(:review)
    expect(described_class.of(working, features: %w[delivery review_turns pair_turns])).to eq(:pair)
    expect(described_class.of(review, features: %w[pair_turns])).to eq(:review)
  end

  describe ".live" do
    def live_with(features)
      sidecar = Samagotchi::WorkerSidecar.new(port: 1, session_id: working.id, features: features)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Live.new(sidecar: sidecar))
    end

    it "reads the live worker's features: an older worker keeps the session review" do
      live_with(%w[delivery review_turns])
      expect(described_class.live(working, state_dir: "/nowhere")).to eq(:review)
      expect(described_class.older_worker?(working, state_dir: "/nowhere")).to be(true)
      live_with(%w[delivery review_turns pair_turns])
      expect(described_class.live(working, state_dir: "/nowhere")).to eq(:pair)
      expect(described_class.older_worker?(working, state_dir: "/nowhere")).to be(false)
    end

    it "is this chi's mode without a live worker" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::None.new)
      expect(described_class.live(working, state_dir: "/nowhere")).to eq(:pair)
      expect(described_class.older_worker?(review, state_dir: "/nowhere")).to be(false)
    end
  end

  it "is named in the worker's features" do
    require "samagotchi/bridge"
    expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::PAIR_FEATURE, Samagotchi::Delivery::REVIEW_FEATURE)
  end
end
