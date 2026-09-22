# frozen_string_literal: true

require "samagotchi/terminal_ui"

RSpec.describe Samagotchi::TerminalUI::EventRenderer do
  # Records the drawing calls; lines carry the duration for easy assertions.
  let(:view) do
    Class.new do
      attr_reader :calls, :lines

      def initialize
        @calls = []
        @lines = []
      end

      def format_tool_activity_line(activity, duration_ms: nil)
        [activity[:tool], duration_ms].compact.join(" ")
      end

      def print_line(text) = @lines << text

      def method_missing(name, *args)
        @calls << name
      end

      def respond_to_missing?(*) = true
    end.new
  end
  let(:now) { [10.0] }
  let(:renderer) { described_class.new(view, clock: -> { now.first }) }
  let(:activity) { { action: "reading file", tool: "read", params: "path=a", status: "ok" } }

  def tool_events(activity, iteration: 1, call_index: 1)
    base = { iteration: iteration, call_index: call_index, tool: activity[:tool] }
    [base.merge(type: :tool_call_started, call: { name: activity[:tool] }), base.merge(type: :tool_call_completed, activity: activity)]
  end

  it "times each tool call from its own started/completed events" do
    started, completed = tool_events(activity)
    renderer.call(started)
    now[0] = 10.25
    renderer.call(completed)

    expect(view.lines).to eq(["read 250.0"])
  end

  it "does not repeat streamed tool activity in the turn summary" do
    other = activity.merge(tool: "execute")
    tool_events(activity).each { |e| renderer.call(e) }

    renderer.call(type: :turn_completed, turn_summary: { tool_activity: [activity, other], output: "done", resumable: false })

    expect(view.lines).to eq(["read 0.0", "execute", "done"])
  end

  it "adds the iteration-limit notice to a resumable summary" do
    renderer.render_turn_summary(tool_activity: [], output: "", resumable: true)

    expect(view.lines).to eq(["", "iteration limit reached"])
  end

  it "resets its bookkeeping at :turn_started" do
    tool_events(activity).each { |e| renderer.call(e) }
    renderer.call(type: :turn_started)

    renderer.render_turn_summary(tool_activity: [activity], output: "x", resumable: false)

    expect(view.lines.last(2)).to eq(["read", "x"])
    expect(view.calls).to include(:reset_turn_feedback)
  end

  describe "events that arrived over the Bridge (JSON, string keys)" do
    def wire(event) = JSON.parse(JSON.generate(event))

    it "renders them exactly as the local symbol-keyed events" do
      events = [
        { type: :turn_started, origin: { client_id: "web:1" } },
        { type: :generation_started, iteration: 1 },
        { type: :generation_chunk, iteration: 1, content: "hi", payload: { "usage" => nil } },
        { type: :generation_retrying, attempt: 2 },
        { type: :generation_completed, iteration: 1 },
        *tool_events(activity),
        { type: :turn_completed, turn_summary: { tool_activity: [activity], output: "done", resumable: true,
                                                  context_status: { est_pct: 12, bucket: :low } } }
      ]
      local = view.class.new
      wired = view.class.new
      local_renderer = described_class.new(local, clock: -> { 10.0 })
      wired_renderer = described_class.new(wired, clock: -> { 10.0 })

      events.each do |e|
        local_renderer.call(e)
        wired_renderer.call(wire(e))
      end

      expect(wired.calls).to eq(local.calls)
      expect(wired.lines).to eq(local.lines)
      expect(wired.lines).to eq(["read 0.0", "done", "iteration limit reached"])
    end

    it "tolerates a chunk or tool call without an iteration or params (ruby_llm backend)" do
      renderer.call(wire(type: :generation_chunk, content: "x"))
      renderer.call(wire(type: :tool_call_started, tool: "read", params: nil))
      renderer.call(wire(type: :tool_call_completed, tool: "read", activity: activity.merge(params: nil)))

      expect(view.lines).to eq(["read 0.0"])
    end
  end

  it "ignores events it does not render" do
    renderer.call(type: :reminder_injected, reminders: [])
    renderer.call(type: :turn_completed, result: "no summary")

    expect(view.lines).to be_empty
    expect(view.calls).to be_empty
  end
end
