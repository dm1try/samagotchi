# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/push/presence"

RSpec.describe Samagotchi::Web::Push::Presence do
  let(:clock) { [100.0] }
  let(:presence) { described_class.new(now: -> { clock[0] }) }

  it "is present while some page's last report is front and younger than 45 s" do
    expect(presence.present?).to be(false)
    presence.report("desk", true)
    presence.report("phone", false)
    clock[0] += 44.9
    expect(presence.present?).to be(true)
    clock[0] += 0.2
    expect(presence.present?).to be(false)
  end

  it "takes a page's newer report over its older one" do
    presence.report("desk", true)
    presence.report("desk", false)
    expect(presence.present?).to be(false)
    presence.report("desk", true)
    expect(presence.present?).to be(true)
  end

  it "remembers at most 64 pages, dropping the longest unheard" do
    presence.report("first", true)
    64.times { |i| presence.report("p#{i}", false) }
    expect(presence.present?).to be(false)
    presence.report("p0", true)
    65.times { |i| presence.report("n#{i}", false) }
    expect(presence.present?).to be(false)
  end

  it "parses {page, front} only" do
    expect(described_class.parse({ "page" => "a1", "front" => false })).to eq(["a1", false])
    expect(described_class.parse({ "page" => "a1" })).to be_nil
    expect(described_class.parse({ "page" => "a1", "front" => 1 })).to be_nil
    expect(described_class.parse("x")).to be_nil
    expect(described_class.parse(nil)).to be_nil
  end
end
