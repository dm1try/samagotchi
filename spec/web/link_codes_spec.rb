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
end
