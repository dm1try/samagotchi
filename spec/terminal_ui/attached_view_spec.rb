# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_view"

RSpec.describe Samagotchi::TerminalUI::AttachedView do
  let(:screen) do
    Class.new do
      attr_reader :lines, :statuses

      def initialize
        @lines = []
        @statuses = []
      end

      def print_line(text) = @lines << text
      def status=(text)
        @statuses << text
      end

      def columns = 40
    end.new
  end
  let(:now) { [0.0] }
  let(:view) { described_class.new(screen, clock: -> { now.first }) }
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

    expect(screen.statuses.compact).to eq(["| thinking…", "/ model> … Let me look", "/ running read…", "/ thinking…"])
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
end
