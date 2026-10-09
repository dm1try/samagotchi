# frozen_string_literal: true

require "spec_helper"
require "samagotchi/delivery"

RSpec.describe Samagotchi::Delivery do
  it "names the three delivery values, next_step first" do
    expect(described_class::VALUES).to eq(%w[next_step cut queue])
    expect(described_class::NEXT_STEP).to eq("next_step")
  end

  describe ".parse" do
    it "answers a known value unchanged" do
      expect(described_class.parse("next_step")).to eq("next_step")
      expect(described_class.parse("cut")).to eq("cut")
      expect(described_class.parse("queue")).to eq("queue")
    end

    it "defaults to next_step for nil, empty and unknown values" do
      expect(described_class.parse(nil)).to eq("next_step")
      expect(described_class.parse("")).to eq("next_step")
      expect(described_class.parse("now")).to eq("next_step")
      expect(described_class.parse(:queue)).to eq("next_step")
    end
  end

  describe "the predicates" do
    it "reads each value on its own" do
      expect(described_class.next_step?(nil)).to be(true)
      expect(described_class.next_step?("next_step")).to be(true)
      expect(described_class.next_step?("cut")).to be(false)

      expect(described_class.cut?("cut")).to be(true)
      expect(described_class.cut?(nil)).to be(false)

      expect(described_class.queue?("queue")).to be(true)
      expect(described_class.queue?(nil)).to be(false)
    end
  end
end
