# frozen_string_literal: true

require "spec_helper"
require "samagotchi/compat"

RSpec.describe Samagotchi::Compat do
  describe ".verdict" do
    it "accepts the current and previous minor, and suggests a restart for older or unknown versions" do
      expect(described_class.verdict(worker_version: "0.160.0")).to eq(:ok)
      expect(described_class.verdict(worker_version: "0.159.9")).to eq(:ok)
      expect(described_class.verdict(worker_version: "0.158.9")).to eq(:restart_suggested)
      expect(described_class.verdict(worker_version: nil)).to eq(:restart_suggested)
    end

    it "refuses a worker speaking a newer protocol before considering its version" do
      expect(described_class.verdict(worker_version: "0.160.0", worker_protocol: 2, protocol: 1)).to eq(:refused)
    end

    it "treats a prerelease below the previous-minor stable floor as needing a restart" do
      # 0.160.0.pre1 is older than the 0.160.0 floor for chi 0.161.0.
      expect(described_class.verdict(worker_version: "0.160.0.pre1", version: "0.161.0"))
        .to eq(:restart_suggested)
    end
  end
end
