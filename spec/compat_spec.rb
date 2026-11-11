# frozen_string_literal: true

require "spec_helper"
require "samagotchi/compat"

RSpec.describe Samagotchi::Compat do
  describe ".verdict" do
    it "accepts the current and previous minor, and suggests a restart for older or unknown versions" do
      expect(described_class.verdict(worker_version: "0.160.0", version: "0.160.0")).to eq(:ok)
      expect(described_class.verdict(worker_version: "0.159.9", version: "0.160.0")).to eq(:ok)
      expect(described_class.verdict(worker_version: "0.158.9", version: "0.160.0")).to eq(:restart_suggested)
      expect(described_class.verdict(worker_version: nil, version: "0.160.0")).to eq(:restart_suggested)
    end

    it "refuses a worker speaking a newer protocol before considering its version" do
      expect(described_class.verdict(worker_version: "0.160.0", version: "0.160.0", worker_protocol: 2, protocol: 1)).to eq(:refused)
    end

    it "treats a prerelease below the previous-minor stable floor as needing a restart" do
      # 0.160.0.pre1 is older than the 0.160.0 floor for chi 0.161.0.
      expect(described_class.verdict(worker_version: "0.160.0.pre1", version: "0.161.0"))
        .to eq(:restart_suggested)
    end
  end

  describe "SHIMS" do
    let(:root) { File.expand_path("..", __dir__) }

    it "has no shim this version is past the remove_after of" do
      overdue = described_class.overdue_shims.map { |shim| "#{shim.id} (remove after #{shim.remove_after}: #{shim.files.join(", ")})" }
      expect(overdue).to be_empty, "remove these compat shims (or move their remove_after): #{overdue.join("; ")}"
    end

    it "names a shim once the version passes its remove_after, and never one the owner hasn't dated" do
      shims = [described_class::Shim.new(id: :a, added_in: "0.1.0", added_on: "2026-11-01", remove_after: "0.2.0",
                                         files: [], what: ""),
               described_class::Shim.new(id: :b, added_in: "0.1.0", added_on: "2026-11-01", remove_after: nil,
                                         files: [], what: "")]

      expect(described_class.overdue_shims(version: "0.2.0", shims: shims, today: Date.new(2026, 11, 20))).to be_empty
      expect(described_class.overdue_shims(version: "0.2.1", shims: shims, today: Date.new(2026, 11, 14))).to be_empty
      expect(described_class.overdue_shims(version: "0.2.1", shims: shims, today: Date.new(2026, 11, 15)).map(&:id))
        .to eq([:a])
    end

    it "keeps each shim's ids unique, its versions valid and its files there, each Ruby file naming it" do
      expect(described_class::SHIMS.map(&:id).uniq.size).to eq(described_class::SHIMS.size)
      described_class::SHIMS.each do |shim|
        expect([shim.added_in, shim.remove_after].compact).to all(satisfy { |version| Gem::Version.correct?(version) })
        expect(Date.iso8601(shim.added_on).iso8601).to eq(shim.added_on)
        shim.files.each do |file|
          path = File.join(root, file)
          expect(File).to exist(path), "#{shim.id}: #{file}"
          next unless file.end_with?(".rb")

          expect(File.read(path)).to include("compat shim #{shim.id}"), "#{file} doesn't name compat shim #{shim.id}"
        end
      end
    end
  end
end
