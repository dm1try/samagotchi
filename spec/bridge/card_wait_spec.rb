# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/bridge/card_wait"

# The page's card_kinds.js cardWait reads the same cases
# (spec/web/public/card_kinds.test.js).
RSpec.describe Samagotchi::Bridge::CardWait do
  cases = JSON.parse(File.read(File.expand_path("../shared/card_wait_cases.json", __dir__)))["cases"]

  cases.each do |c|
    it "#{c["name"]}: #{c["kind"].inspect}, from string and symbol keys" do
      expect(described_class.kind(c["card"])).to eq(c["kind"])
      expect(described_class.kind(JSON.parse(JSON.generate(c["card"]), symbolize_names: true))).to eq(c["kind"])
    end
  end

  it "is nil for anything but a Hash" do
    expect(described_class.kind(nil)).to be_nil
    expect(described_class.kind("card")).to be_nil
  end
end
