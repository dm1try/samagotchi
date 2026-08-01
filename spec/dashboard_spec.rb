
# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/dashboard"

RSpec.describe Samagotchi::Dashboard do
  describe "constants" do
    it "has correct command strings" do
      expect(described_class::QUIT_COMMAND).to eq("/quit")
      expect(described_class::DETACH_COMMAND).to eq("/detach")
      expect(described_class::STOP_COMMAND).to eq("/stop")
      expect(described_class::CONTINUE_PROMPT).to eq("/continue")
    end
  end

  describe "#initialize" do
    it "creates with empty sessions" do
      dashboard = described_class.new
      expect(dashboard.instance_variable_get(:@sessions)).to eq([])
    end
  end
end

