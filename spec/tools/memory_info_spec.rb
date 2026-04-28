# frozen_string_literal: true

require "samagotchi/tools/memory_info"

RSpec.describe Samagotchi::Tools::MemoryInfo do
  describe ".name" do
    it "is 'memory_info'" do
      expect(described_class.name).to eq("memory_info")
    end
  end

  describe ".call" do
    subject(:result) { described_class.call }

    it "returns a non-empty string" do
      expect(result).to be_a(String)
      expect(result).not_to be_empty
    end

    it "includes RSS memory info" do
      expect(result).to match(/RSS/i)
    end

    it "includes GC count" do
      expect(result).to match(/gc_count/i)
    end

    it "includes heap_live_slots" do
      expect(result).to match(/heap_live_slots/i)
    end
  end
end
