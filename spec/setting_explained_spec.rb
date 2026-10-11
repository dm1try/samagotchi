# frozen_string_literal: true

require_relative "../lib/samagotchi/setting_explained"

RSpec.describe Samagotchi::SettingExplained do
  it "labels a level with its source, and the default without one" do
    expect(described_class.new(level: :low, source: "session", own: :low).label).to eq("low (session)")
    expect(described_class.new(level: :default, source: nil, own: nil).label).to eq("default")
  end

  it "summarizes as plain strings" do
    expect(described_class.new(level: :all, source: "session", own: :all).summary)
      .to eq(level: "all", source: "session", own: "all")
    expect(described_class.new(level: :turn, source: nil, own: nil).summary).to eq(level: "turn", source: nil, own: nil)
  end
end
