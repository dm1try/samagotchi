# frozen_string_literal: true

require "time"
require "samagotchi/participant_turn_mode"
require "samagotchi/participants"
require "samagotchi/verify_fresh_origin"
require "samagotchi/session"

RSpec.describe Samagotchi::ParticipantTurnMode do
  let(:now) { Time.utc(2026, 11, 14, 12) }
  let(:anchor) { Samagotchi::VerifyAnchor.from({ turn_id: "t1", quote: "the claim" }) }

  def entry(mode: "pair", removed_at: nil, expires_at: (now + 3600).iso8601)
    Samagotchi::Participants::Entry.new(id: "p_0123abcd", name: "Sam", role: "reviewer", added_at: now.iso8601,
                                        expires_at: expires_at, removed_at: removed_at, cap: nil, mode: mode)
  end

  def session(verify_fresh: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd).tap do |s|
      s.verify_fresh = verify_fresh
    end
  end

  def fresh(author:, mode:) = Samagotchi::VerifyFreshOrigin.new(author: author, mode: mode, of: "t2", anchor: anchor)

  def mode_of(entry, session) = described_class.of(entry: entry, session: session, now: now)

  it "runs a current pair invite's turn in a session" do
    expect(mode_of(entry, session)).to eq(:pair)
  end

  it "refuses no invite, a revoked or expired one, and anything that isn't an entry, as revoked" do
    expect(mode_of(nil, session)).to eq(:revoked)
    expect(mode_of(entry(removed_at: now.iso8601), session)).to eq(:revoked)
    expect(mode_of(entry(expires_at: (now - 1).iso8601), session)).to eq(:revoked)
    expect(mode_of(entry(expires_at: "never"), session)).to eq(:revoked)
    expect(mode_of(Struct.new(:mode).new("pair"), session)).to eq(:revoked)
    expect(mode_of("pair", session)).to eq(:revoked)
  end

  it "refuses an older chi's read-only invite as outdated while it is current, as revoked once it ended" do
    expect(mode_of(entry(mode: nil), session)).to eq(:outdated)
    expect(mode_of(entry(mode: "review"), session)).to eq(:outdated)
    expect(mode_of(entry(mode: nil, removed_at: now.iso8601), session)).to eq(:revoked)
  end

  it "refuses a turn with no session as not invited" do
    expect(mode_of(entry, nil)).to eq(:not_invited)
  end

  it "runs a participant's own pair Verify fresh child, refuses a read-only one as outdated" do
    expect(mode_of(entry, session(verify_fresh: fresh(author: "p:p_0123abcd", mode: "pair")))).to eq(:pair)
    expect(mode_of(entry, session(verify_fresh: fresh(author: "p:p_0123abcd", mode: "review")))).to eq(:outdated)
    expect(mode_of(entry, session(verify_fresh: Samagotchi::VerifyFreshOrigin::INVALID))).to eq(:outdated)
  end

  it "refuses a participant's turn in the owner's own Verify fresh child as not invited" do
    expect(mode_of(entry, session(verify_fresh: fresh(author: nil, mode: nil)))).to eq(:not_invited)
  end

  it "says which modes are this chi's invite" do
    expect(described_class.invite_mode?("pair")).to be(true)
    expect(described_class.invite_mode?(:pair)).to be(true)
    expect([nil, "review", ""].map { |mode| described_class.invite_mode?(mode) }).to all(be(false))
    expect(Samagotchi::Grants::PAIR_MODE).to eq(described_class::PAIR_MODE)
  end
end
