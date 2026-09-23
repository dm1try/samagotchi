# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_view"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedView do
  let(:screen) { RecordingSurface.new(columns: 40) }
  let(:now) { [0.0] }
  let(:view) { described_class.new(screen, clock: -> { now.first }, tick_interval: nil) }
  let(:renderer) { Samagotchi::TerminalUI::EventRenderer.new(view, clock: -> { now.first }) }

  def feed(*events)
    events.each do |e|
      now[0] += 1.0
      renderer.call(JSON.parse(JSON.generate(e)))
    end
  end

  it "shows a turn as a status line, then its tool line and answer as output" do
    activity = { action: "reading file", tool: "read", params: "path=a", status: "ok" }
    feed({ type: :turn_started },
         { type: :generation_started, iteration: 1 },
         { type: :generation_chunk, iteration: 1, content: "Let me look" },
         { type: :tool_dispatch_started, iteration: 1 },
         { type: :tool_call_started, iteration: 1, call_index: 0, tool: "read" },
         { type: :tool_call_completed, iteration: 1, call_index: 0, tool: "read", activity: activity },
         { type: :generation_started, iteration: 2 },
         { type: :generation_completed, iteration: 2 },
         { type: :turn_completed, turn_summary: { tool_activity: [activity], output: "It says hi.", resumable: false,
                                                   context_status: { est_pct: 7, bucket: "low" } } })

    # Whole seconds apart: the spinner (4 frames a second) is on "|" each time.
    expect(screen.statuses.compact).to eq(["| thinking…", "| model> … Let me look", "| running read…", "| thinking…"])
    expect(screen.statuses.last).to be_nil
    expect(screen.lines.size).to eq(2)
    expect(screen.lines.first).to include("reading file (read path=a): ok")
    expect(screen.lines.last).to eq("It says hi.")
    expect(view.context_status).to eq(est_pct: 7, bucket: "low")
  end

  it "keeps the end of the model's text within the terminal width" do
    feed({ type: :generation_started, iteration: 1 },
         { type: :generation_chunk, iteration: 1, content: "#{"a" * 60}END" })

    status = screen.statuses.last
    expect(status).to end_with("aEND")
    expect(status.length).to eq(39)
  end

  it "redraws the status line at most every so often while chunks stream" do
    feed({ type: :generation_started, iteration: 1 })
    before = screen.statuses.size
    now[0] += 1.0
    10.times { |i| view.generation_feedback_chunk(content: i.to_s) }

    expect(screen.statuses.size - before).to eq(1)
  end

  describe "the time-based spinner" do
    it "turns with time while no chunks come, then says how long it has waited for the first token" do
      view.generation_feedback_started
      [0.25, 0.5, 0.75, 1.0].each do |t|
        now[0] = t
        view.tick
      end
      now[0] = 2.3
      view.tick

      expect(screen.statuses).to eq(["| thinking…", "/ thinking…", "- thinking…", "\\ thinking…", "| thinking…",
                                     "/ waiting for the first token… 2s"])
    end

    it "stops counting at the first chunk, and again after a retry" do
      view.generation_feedback_started
      now[0] = 5.0
      view.generation_feedback_chunk(content: "Hi")
      now[0] = 9.0
      view.tick
      expect(screen.statuses.last).to eq("| model> … Hi")

      view.generation_feedback_retrying(attempt: 1)
      view.generation_feedback_chunk(content: "")
      view.generation_feedback_started
      now[0] = 12.0
      view.tick
      expect(screen.statuses.last).to eq("| waiting for the first token… 3s")
    end

    it "does nothing once the slot is gone" do
      view.generation_feedback_started
      view.finish_thinking_spinner
      before = screen.statuses.size

      expect(view.tick).to be(false)
      expect(screen.statuses.size).to eq(before)
    end

    it "runs a ticker thread while the slot is shown, which ends with it" do
      real = described_class.new(screen, tick_interval: 0.02)
      real.generation_feedback_started
      sleep 0.15
      expect(screen.statuses.size).to be > 3

      real.finish_thinking_spinner
      sleep 0.05
      after = screen.statuses.size
      sleep 0.08
      expect(screen.statuses.size).to eq(after)
      real.stop
    end

    it "stops its ticker when the loop ends mid-turn" do
      real = described_class.new(screen, tick_interval: 0.02)
      real.generation_feedback_started
      real.stop
      after = screen.statuses.size
      sleep 0.08

      expect(screen.statuses.size).to eq(after)
    end
  end
end
