# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/link_codes"

RSpec.describe Samagotchi::Web::LinkCodes do
  let(:dir) { Dir.mktmpdir("link-codes") }
  let(:now) { [Time.utc(2026, 10, 24, 12)] }
  let(:codes) { described_class.for_grants(File.join(dir, "web-grants", "grants.json"), clock: -> { now.first }) }
  let(:token) { "chp_#{"t" * 43}" }

  after { FileUtils.remove_entry(dir) }

  it "redeems an owner's code once" do
    code = codes.issue(kind: :owner, ttl: 600)
    expect(code).to match(described_class::CODE_RE)
    expect(codes.redeem(code)).to eq([:owner, nil])
    expect(codes.redeem(code)).to be_nil
  end

  it "keeps a grant's token sealed under the code: the store has neither the code nor the token" do
    code = codes.issue(kind: :grant, token: token, ttl: 600)
    stored = File.read(codes.path)
    expect(stored).not_to include(token)
    expect(stored).not_to include(code)
    expect(File.stat(codes.path).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(codes.path)).mode & 0o777).to eq(0o700)
    expect(codes.redeem(code)).to eq([:grant, token])
  end

  # Decision C: a bound grant's code opened by another identity is refused
  # and kept for the one it was sent to.
  it "keeps a code its block declines, untouched, and gives it out once accepted" do
    code = codes.issue(kind: :grant, token: token, ttl: 600)
    before = File.binread(codes.path)
    asked = []
    expect(codes.redeem(code) { |kind, found| (asked << [kind, found]) && false }).to be_nil
    expect(asked).to eq([[:grant, token]])
    expect(File.binread(codes.path)).to eq(before)
    expect(codes.redeem(code) { true }).to eq([:grant, token])
    expect(codes.redeem(code) { true }).to be_nil
  end

  it "never asks the block about an expired or unknown code" do
    code = codes.issue(kind: :grant, token: token, ttl: 600)
    now[0] += 601
    expect(codes.redeem(code) { raise "asked" }).to be_nil
    expect(codes.redeem("chc_#{"a" * 43}") { raise "asked" }).to be_nil
  end

  it "refuses an expired code, and drops expired ones at the next write" do
    code = codes.issue(kind: :owner, ttl: 600)
    now[0] += 601
    expect(codes.redeem(code)).to be_nil
    codes.issue(kind: :owner, ttl: 600)
    expect(JSON.parse(File.read(codes.path))["codes"].size).to eq(1)
  end

  it "refuses anything that isn't a code, and a code it never issued" do
    expect(codes.redeem(nil)).to be_nil
    expect(codes.redeem(token)).to be_nil
    expect(codes.redeem("chc_#{"a" * 43}")).to be_nil
  end

  # A guessed code costs a read under the lock, never a write of the store.
  it "doesn't rewrite the store for a code it doesn't have, only when one goes" do
    codes.issue(kind: :owner, ttl: 600)
    before = File.stat(codes.path).ino
    expect(codes.redeem("chc_#{"a" * 43}")).to be_nil
    expect(File.stat(codes.path).ino).to eq(before)
    now[0] += 601
    codes.redeem("chc_#{"b" * 43}")
    expect(File.stat(codes.path).ino).not_to eq(before)
    expect(JSON.parse(File.read(codes.path))["codes"]).to eq([])
  end
end
