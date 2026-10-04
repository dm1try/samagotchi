# frozen_string_literal: true

require "spec_helper"
require "samagotchi/vision_context"

RSpec.describe Samagotchi::ImagePlan do
  describe ".dropped_count" do
    it "drops nothing up to the limit, then the oldest in steps of limit/2" do
      expect((18..41).map { |total| described_class.dropped_count(total, 20) })
        .to eq([0, 0, 0] + ([10] * 10) + ([20] * 10) + [30])
    end

    it "steps by one image when the limit is 1" do
      expect((1..4).map { |total| described_class.dropped_count(total, 1) }).to eq([0, 1, 2, 3])
    end

    it "always sends between limit - step + 1 and limit images" do
      (1..9).each do |limit|
        ((limit + 1)..60).each do |total|
          sent = total - described_class.dropped_count(total, limit)
          expect(sent).to be_between(limit - [limit / 2, 1].max + 1, limit)
        end
      end
    end
  end
end
