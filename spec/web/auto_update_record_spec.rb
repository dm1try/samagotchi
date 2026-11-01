# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/web/auto_update_record"

RSpec.describe Samagotchi::Web::AutoUpdateRecord do
  let(:now) { Time.utc(2026, 10, 30, 12) }

  def through_json(record) = described_class.from_h(JSON.parse(JSON.generate(record.to_store)))

  it "comes back from JSON equal to what went in" do
    record = described_class.new(version: "1.2.3", from: "1.2.2", at: now.iso8601, kept: ["a.md"], phase: "failed",
                                 restarted: 2, left: 1, detail: "boom", pushed: true)

    expect(through_json(record)).to eq(record)
  end

  it "comes back equal with only its required fields" do
    record = described_class.new(version: "1.2.3", phase: "installed")

    expect(through_json(record)).to eq(record)
  end

  it "keeps the workers' counts under `workers` in the file, and leaves out what is unset" do
    store = described_class.new(version: "1.2.3", phase: "web", restarted: 2, left: 1).to_store

    expect(store).to include("workers" => { "restarted" => 2, "left" => 1 })
    expect(store.keys).not_to include("detail", "pushed", "from", "at")
  end

  it "reads a record an earlier chi wrote" do
    record = described_class.from_h("version" => "1.2.3", "from" => "1.2.2", "at" => now.iso8601, "kept" => [], "phase" => "web",
                                    "workers" => { "restarted" => 2, "left" => 1 }, "unknown" => "ignored")

    expect(record).to have_attributes(phase: "web", restarted: 2, left: 1, pushed: false)
  end

  it "counts no workers when a record names none" do
    expect(described_class.from_h("version" => "1.2.3", "phase" => "installed")).to have_attributes(restarted: 0, left: 0)
    expect(described_class.from_h("version" => "1.2.3", "phase" => "web", "workers" => "two")).to have_attributes(restarted: 0)
  end

  it "is no record without a version or a phase to go on" do
    [nil, "x", [], {}, { "phase" => "web" }, { "version" => "1.2.3" }, { "version" => "not a version", "phase" => "web" },
     { "version" => 3, "phase" => "web" }, { "version" => "1.2.3", "phase" => 1 }].each do |hash|
      expect(described_class.from_h(hash)).to be_nil
    end
  end

  describe "#left_to_try?" do
    def record(left:, at: now.iso8601) = described_class.new(version: "1.2.3", phase: "workers", left: left, at: at)

    it "holds while workers are left, inside the window" do
      expect(record(left: 1).left_to_try?(now + 99, 100)).to be(true)
    end

    it "ends at the window's end" do
      expect(record(left: 1).left_to_try?(now + 100, 100)).to be(false)
    end

    it "ends with nothing left" do
      expect(record(left: 0).left_to_try?(now, 100)).to be(false)
    end

    it "ends when the stamp can't be read, so a run can't go on for ever" do
      expect(record(left: 1, at: "yesterday").left_to_try?(now, 100)).to be(false)
      expect(record(left: 1, at: nil).left_to_try?(now, 100)).to be(false)
    end
  end
end
