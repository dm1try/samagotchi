# frozen_string_literal: true

require "samagotchi/terminal_ui/gap_clock"
require "samagotchi/terminal_ui/formatting"

RSpec.describe Samagotchi::TerminalUI::GapClock do
  # Local times: one zone, so the expectations hold on any machine.
  around { |example| with_env("TZ" => "Europe/Berlin") { example.run } }

  let(:wall) { [Time.utc(2026, 10, 24, 12, 0, 0)] }
  let(:gaps) { described_class.new(now: -> { wall.first }) }

  def pass(minutes) = wall[0] += minutes * 60

  it "marks nothing for the first activity, then a gap of GAP_SECONDS or more since the last" do
    expect(gaps.divider).to be_nil
    pass(9)
    expect(gaps.divider).to be_nil
    pass(10)
    expect(gaps.divider).to eq("── 14:19 · 10 min later ──")
  end

  it "measures from the end of the last activity: a touch or a quiet mark moves it, with no divider" do
    gaps.divider
    pass(40)
    expect(gaps.divider(quiet: true)).to be_nil
    pass(5)
    gaps.touch
    pass(5)
    expect(gaps.divider).to be_nil
  end

  it "seeds from the newest stamped message (either key kind), else the fallback, else nothing" do
    expect(gaps.seed([{ role: "user" }], fallback: nil)).to be_nil
    expect(gaps.seed([{ "role" => "user", "at" => "2026-10-24T11:00:00.000Z" }, { role: "tool" }]))
      .to eq("2026-10-24T11:00:00.000Z")
    expect(gaps.seed([{ role: "user" }], fallback: "2026-10-24T11:30:00Z")).to eq("2026-10-24T11:30:00.000Z")
    expect(gaps.divider).to eq("── 14:00 · 30 min later ──")
  end

  it "says when the last activity was a gap ago, once, the day added when it was another day" do
    gaps.seed([{ at: "2026-10-24T11:13:00Z" }])
    expect(gaps.join_line).to eq("── last activity 13:13 · 47 min ago ──")
    expect(gaps.join_line).to be_nil
    expect(gaps.divider).to be_nil

    gaps.seed([{ at: "2026-10-22T09:10:00Z" }])
    expect(gaps.join_line).to eq("── last activity Thu 22 Oct 11:10 · 2 d ago ──")
  end

  it "says nothing at the join when the last activity is recent or unknown" do
    expect(gaps.join_line).to be_nil
    gaps.seed([{ at: "2026-10-24T11:55:00Z" }])
    expect(gaps.join_line).to be_nil
  end

  describe "in Formatting" do
    let(:format) { Class.new { include Samagotchi::TerminalUI::Formatting }.new }

    it "puts the recap's local time in its head, before the turns since" do
      expect(format.send(:recap_block, "Did X.", at: "2026-10-24T12:32:00Z")).to eq("recap 14:32> Did X.")
      expect(format.send(:recap_block, "Did X.\nThen Y.", turns_since: 2, at: "2026-10-24T12:32:00Z"))
        .to eq("recap 14:32 (before the last 2 turns)> Did X.\nThen Y.")
      expect(format.send(:recap_block, "Did X.", turns_since: 1)).to eq("recap (before the last turn)> Did X.")
    end

    it "draws a gap's divider dim on a colour terminal" do
      allow(format).to receive(:color_output?).and_return(true)
      expect(format.send(:gap_divider, "── 14:32 · 47 min later ──")).to eq("\e[2m── 14:32 · 47 min later ──\e[0m")
    end
  end
end
