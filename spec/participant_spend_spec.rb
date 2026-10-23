# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session_metrics"
require "samagotchi/side_usage"
require "samagotchi/analytics_file"
require "samagotchi/terminal_ui/formatting"
require "samagotchi/engine"
require "support/test_kernel"

# What each participant costs the owner (D7): their turns' reported and
# estimated cost and the side requests they caused, by author, live and
# from the saved analytics (chi web's cap check). The owner's spend has no
# row, so an owner session's snapshot stays as it was.
RSpec.describe "a participant's spend" do
  let(:metrics) { Samagotchi::SessionMetrics.new(clock: -> { 0.0 }, wall_clock: -> { Time.utc(2026, 10, 23, 10) }) }
  let(:alex) { "p:p_0123abcd" }

  def chunk(cost)
    usage = { "prompt_tokens" => 1000, "completion_tokens" => 10, "cost" => cost }
    { type: :generation_chunk, iteration: 1, content: "", payload: { "choices" => [], "usage" => usage } }
  end

  def turn(id, cost, author: nil, finish: true)
    origin = author ? { client_id: "review:x", author: author } : { client_id: "web:t" }
    metrics.call(type: :turn_started, session_id: "s1", prompt: "p", turn_id: id, origin: origin)
    metrics.call(type: :generation_started, iteration: 1)
    metrics.call(chunk(cost))
    metrics.call(type: :generation_completed, iteration: 1)
    metrics.call(type: :turn_completed) if finish
  end

  it "counts a participant's turns and the side requests they caused, never the owner's" do
    turn("t1", 0.5)
    turn("t2", 0.25, author: alex)
    metrics.add_side(Samagotchi::SideUsage.new(kind: "recap", cost: 0.125, author: alex))
    metrics.add_side(Samagotchi::SideUsage.new(kind: "btw", cost: 1.0))

    expect(metrics.spend(alex)).to eq(0.375)
    expect(metrics.spend("p:p_other")).to eq(0.0)
    expect(metrics.snapshot[:spend_by_author]).to eq(alex => { turns: 1, cost: 0.375, side_cost: 0.125 })
    expect(metrics.snapshot[:side][:by_author]).to eq(alex => { requests: 1, cost_sum: 0.125, cost_estimate_sum: 0 })
  end

  it "counts the running turn's finished generations" do
    turn("t1", 0.5, author: alex, finish: false)
    expect(metrics.spend(alex)).to eq(0.5)
  end

  it "keeps an owner session's snapshot without the new keys" do
    turn("t1", 0.5)
    metrics.add_side(Samagotchi::SideUsage.new(kind: "recap", cost: 0.1))
    expect(metrics.snapshot).not_to have_key(:spend_by_author)
    expect(metrics.snapshot[:side]).not_to have_key(:by_author)
  end

  it "reads a participant's spend from the saved analytics, and keeps it across a reload" do
    dir = Dir.mktmpdir("participant-spend")
    turn("t1", 0.5, author: alex)
    metrics.add_side(Samagotchi::SideUsage.new(kind: "recap", cost: 0.25, author: alex))
    File.write(Samagotchi::AnalyticsFile.path(dir), JSON.generate(metrics.saved_snapshot))

    expect(Samagotchi::SessionMetrics.saved_spend(dir, alex)).to eq(0.75)
    expect(Samagotchi::SessionMetrics.saved_spend(dir, "p:p_other")).to eq(0.0)
    expect(Samagotchi::SessionMetrics.saved_spend(File.join(dir, "none"), alex)).to eq(0.0)
  ensure
    FileUtils.rm_rf(dir)
  end

  it "shows each participant's spend in /stats, by name" do
    rows = { alex => { turns: 3, cost: 0.42, name: "Alex" }, "p:p_beef0000" => { turns: 1, cost: 0.1 } }
    text = Samagotchi::TerminalUI::Formatting.format_session_metrics({ turns: 4, spend_by_author: rows })
    expect(text.lines.map(&:chomp))
      .to include("participants:     Alex $0.42 (3 turns), p_beef0000 $0.10 (1 turn) (in the totals above)")
    expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ turns: 1 })).not_to include("participants:")
  end

  describe Samagotchi::Engine, "#note_side_usage" do
    let(:engine) { described_class.new(client: test_client, kernel: test_kernel) }

    before { engine.instance_variable_get(:@guardrail_wiring).begin_turn({ client_id: "review:x", author: alex }) }

    it "charges a side request in a participant's turn, and the recap after it, to them; an owner's command's to the owner" do
      allow(engine).to receive(:turn_running?).and_return(true)
      engine.note_side_usage(Samagotchi::SideUsage.new(kind: "btw", cost: 0.25))
      allow(engine).to receive(:turn_running?).and_return(false)
      engine.note_side_usage(Samagotchi::SideUsage.new(kind: "recap", cost: 0.5))
      engine.note_side_usage(Samagotchi::SideUsage.new(kind: "btw", cost: 1.0))

      expect(engine.metrics.spend(alex)).to eq(0.75)
      expect(engine.metrics.snapshot[:side][:requests]).to eq(3)
    end
  end
end
