# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "spec_helper"
require "samagotchi/schedules"
require "samagotchi/schedule_display"

# ScheduleDisplay's state and off reason over the fixture store
# (spec/fixtures/schedules/listing_store.json): one schedule per state a
# listing tells apart. The CLI's goldens (schedule_command_spec) pin the
# words; this pins the reasons.
RSpec.describe Samagotchi::ScheduleDisplay do
  around do |example|
    Dir.mktmpdir("schedule-display") do |tmp|
      @dir = File.join(tmp, "sessions")
      FileUtils.mkdir_p(@dir)
      FileUtils.cp(File.expand_path("fixtures/schedules/listing_store.json", __dir__), File.join(tmp, "schedules.json"))
      example.run
    end
  end

  before do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("schedule.tick_interval_minutes").and_return(5)
  end

  let(:entries) { Samagotchi::Schedules.new(state_dir: @dir).entries(include_disabled: true).to_h { |entry| [entry.title || entry.id, entry] } }

  def reasons = entries.transform_values { |entry| [described_class.state(entry), described_class.off_reason(entry)] }

  it "tells each state and why an off schedule is off" do
    expect(reasons).to eq(
      "Heartbeat" => %w[on] + [nil],
      "b2c3d4e5" => %w[off owner],
      "Pod logs" => %w[off skips],
      "Nightly build" => %w[off failures],
      "Release notes" => %w[off done],
      "Demo prep" => %w[off failures],
      "Dentist" => %w[off missed],
      "Quarterly" => %w[off done],
      "Standup" => ["firing", nil],
      "Inbox" => ["firing", nil]
    )
  end

  it "reads a one-off's reason from its last outcome, never from enabled: false alone" do
    one_off = entries.fetch("Release notes")
    expect(described_class.off_reason(one_off.with(history: []))).to eq("off")
    expect(described_class.off_reason(one_off.with(history: one_off.history + [{ status: "failed", detail: "boom" }]))).to eq("failures")
    expect(described_class.off_reason(one_off.with(history: one_off.history + [{ status: "edited", detail: "title" }]))).to eq("done")
  end

  it "puts name, state and off_reason after the stored fields, so an extra key never shadows them" do
    entry = entries.fetch("Heartbeat")
    shadowed = entry.with(extra: entry.extra.merge("state" => "theirs", "name" => "theirs", "off_reason" => "theirs"))
    json = described_class.json(shadowed)
    expect(json.values_at("name", "state", "off_reason")).to eq(["Heartbeat", "on", nil])
    expect(json["future_key"]).to eq({ "from" => "a newer chi" })
  end
end
