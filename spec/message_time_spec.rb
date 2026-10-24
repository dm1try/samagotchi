# frozen_string_literal: true

require "samagotchi/message_time"

RSpec.describe Samagotchi::MessageTime do
  # The clock texts are local time: pinned to one zone (CI runs in UTC, a
  # developer's Mac doesn't), one whose day differs from UTC's at 23:30Z.
  around { |example| with_env("TZ" => "Europe/Berlin") { example.run } }

  # 2026-10-24 is a Saturday; Berlin is UTC+2 then.
  def local(*parts) = Time.new(*parts, "+02:00")

  describe ".now" do
    it "reads the source a spec sets, and Time.now after reset!" do
      described_class.source = -> { Time.at(0) }
      expect(described_class.now).to eq(Time.at(0))

      described_class.reset!
      expect(described_class.now).to be_within(5).of(Time.now)
    end
  end

  describe ".iso" do
    it "writes the time with its offset and milliseconds" do
      expect(described_class.iso(local(2026, 10, 24, 9, 5, 7.25r))).to eq("2026-10-24T09:05:07.250+02:00")
    end
  end

  describe ".iso_of" do
    it "restamps an ISO text from elsewhere, and is nil for none or garbage" do
      expect(described_class.iso_of("2026-10-24T07:05:07Z")).to eq("2026-10-24T07:05:07.000Z")
      expect(described_class.iso_of(nil)).to be_nil
      expect(described_class.iso_of("yesterday")).to be_nil
    end
  end

  describe ".stamp" do
    it "sets the key once: a stamp the message has stays, Symbol or String keyed" do
      time = local(2026, 10, 24, 9, 0, 0)

      expect(described_class.stamp({ role: "user" }, time)).to eq(role: "user", at: "2026-10-24T09:00:00.000+02:00")
      expect(described_class.stamp({ role: "user", at: "kept" }, time)).to eq(role: "user", at: "kept")
      expect(described_class.stamp({ "role" => "user", "at" => "kept" }, time)).to eq("role" => "user", "at" => "kept")
      expect(described_class.stamp({ role: "user" }, "2026-10-24T09:00:00.000+02:00")[:at]).to eq("2026-10-24T09:00:00.000+02:00")
    end
  end

  describe ".of" do
    it "reads a stamp under either key type, nil for none" do
      expect(described_class.of({ at: "a" })).to eq("a")
      expect(described_class.of({ "at" => "b" })).to eq("b")
      expect(described_class.of({ role: "user" })).to be_nil
      expect(described_class.of(nil)).to be_nil
    end
  end

  describe ".clock and .day_clock" do
    it "shows the local time of a stamp in any offset" do
      expect(described_class.clock("2026-10-24T12:32:00Z")).to eq("14:32")
      expect(described_class.day_clock("2026-10-24T07:10:00Z")).to eq("Sat 24 Oct 09:10")
      expect(described_class.clock("not a time")).to be_nil
      expect(described_class.clock(nil)).to be_nil
    end
  end

  describe ".gap_line" do
    it "prints nothing below ten minutes of quiet" do
      expect(described_class.gap_line("2026-10-24T09:00:00+02:00", "2026-10-24T09:09:59+02:00")).to be_nil
    end

    it "prints the next activity's time and the gap from ten minutes on" do
      expect(described_class.gap_line("2026-10-24T09:00:00+02:00", "2026-10-24T09:10:00+02:00"))
        .to eq("── 09:10 · 10 min later ──")
      expect(described_class.gap_line("2026-10-24T13:45:00+02:00", "2026-10-24T14:32:30+02:00"))
        .to eq("── 14:32 · 47 min later ──")
    end

    it "adds the date when the local day changed, whatever the stamps' offsets" do
      expect(described_class.gap_line("2026-10-23T20:00:00+02:00", "2026-10-24T07:10:00Z"))
        .to eq("── Sat 24 Oct 09:10 · 13 h later ──")
      # 21:00Z and 22:30Z are one UTC day, two Berlin days.
      expect(described_class.gap_line("2026-10-24T21:00:00Z", "2026-10-24T22:30:00Z"))
        .to eq("── Sun 25 Oct 00:30 · 1 h later ──")
    end

    it "prints nothing when either time is unknown, or the order is backwards" do
      expect(described_class.gap_line(nil, "2026-10-24T09:10:00+02:00")).to be_nil
      expect(described_class.gap_line("2026-10-24T09:10:00+02:00", "bad")).to be_nil
      expect(described_class.gap_line("2026-10-24T10:00:00+02:00", "2026-10-24T09:00:00+02:00")).to be_nil
    end
  end

  describe ".ago" do
    it "rounds down to the largest whole unit, as the web's relativeTime does" do
      expect(described_class.ago(600)).to eq("10 min")
      expect(described_class.ago(3599)).to eq("59 min")
      expect(described_class.ago(3600)).to eq("1 h")
      expect(described_class.ago(86_399)).to eq("23 h")
      expect(described_class.ago((2 * 86_400) + 5)).to eq("2 d")
    end
  end
end
