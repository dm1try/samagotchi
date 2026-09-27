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

  it "prints the answer a merge follows, then the merge note" do
    renderer.call({ type: :pending_input_merged, count: 1, content: "also", answer: "the essay" })
    renderer.call({ type: :pending_input_merged, count: 2, content: "a\n\nb" })

    expect(view.lines).to eq(["the essay", "(1 message merged into the running turn)",
                              "(2 messages merged into the running turn)"])
    expect(view.calls).to include(:finish_thinking_spinner)
  end

  it "prints a hook's notice under the bundle's name, or as hook" do
    renderer.call({ type: :hook_notice, hook: "known_names.rb (bundle known-names)", text: 'rejected execute: "x" looks like "y"', level: :info })
    renderer.call({ type: :hook_notice, hook: "audit.rb (config)", text: "stopped the turn: enough", level: :warn })
    expect(view.lines).to eq(['known-names> rejected execute: "x" looks like "y"', "hook> warning: stopped the turn: enough"])
  end

  describe "cards" do
    let(:view) do
      Class.new do
        include Samagotchi::TerminalUI::Formatting
        attr_reader :lines

        def initialize = @lines = []
        def print_line(text) = @lines << text
        def color_output? = false
        def card_width = 40
      end.new
    end
    let(:card) do
      { type: :card, id: "c1", source: "sample-plugin", title: "Hello", level: :info,
        body: "hello, Jordan (session 3f2a, 2 messages). A longer line that wraps at the frame's width.\n\n  - kept indent",
        actions: [{ label: "Again", command: "/hello again" }, { label: "/x", command: "/x" }] }
    end

    it "prints a framed block: the title and source, the wrapped body, the actions" do
      renderer.call(card)
      expect(view.lines.last.split("\n")).to eq([
        "┌ Hello · sample-plugin",
        "│ hello, Jordan (session 3f2a, 2",
        "│ messages). A longer line that wraps at",
        "│ the frame's width.",
        "│",
        "│   - kept indent",
        "│ → /hello again  Again",
        "│ → /x",
        "└"
      ])
    end

    it "prints a card shown again under its id, marked (updated)" do
      renderer.call(card)
      renderer.call(card.merge(title: "Hello 2", body: "", actions: []))
      expect(view.lines.last.split("\n")).to eq(["┌ Hello 2 (updated) · sample-plugin", "└"])
      expect(renderer.card_shown?("c1")).to be true
      expect(renderer.card_shown?("c2")).to be false
    end

    it "shows the body's markdown plain: bold, code and headings' marks go, lists stay" do
      body = "## Counts\nThis session has **2** messages, __new__.\n\n- from the `sample-plugin` bundle\n```\nx = 1\n```"
      renderer.call(card.merge(body: body, actions: []))
      expect(view.lines.last.split("\n")).to eq([
        "┌ Hello · sample-plugin",
        "│ Counts",
        "│ This session has 2 messages, new.",
        "│",
        "│ - from the sample-plugin bundle",
        "│ x = 1",
        "└"
      ])
    end

    it "splits a word longer than a line" do
      expect(view.wrap_plain("#{"x" * 25} y", 10)).to eq(["xxxxxxxxxx", "xxxxxxxxxx", "xxxxx y"])
      expect(view.wrap_plain(" \n ", 10)).to eq([])
    end
  end

  it "prints a guardrail load warning" do
    renderer.call({ type: :guardrail_warning, message: "hook g.rb (config) failed to load (x)" })
    expect(view.lines).to eq(["guardrails> hook g.rb (config) failed to load (x)"])
    renderer.call({ type: :guardrail_warning, message: "plugin plugin.rb (bundle b) failed to load (x)", label: "plugins" })
    expect(view.lines.last).to eq("plugins> plugin plugin.rb (bundle b) failed to load (x)")
  end

  it "hands a completed tool call to the view (for its tally)" do
    renderer.call(tool_events(activity).last)
    expect(view.calls).to include(:tool_call_feedback_completed)
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

    it "tolerates a chunk or tool call without an iteration or params (the old chat backend)" do
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

  describe ".init_line" do
    it "says a task started, and done with its summary; nothing for a failure (its card says it)" do
      started = { "type" => "plugin_init_started", "bundle" => "mcp", "id" => "mcp-1", "label" => "Starting x" }
      expect(described_class.init_line(described_class.symbolize(started))).to eq("mcp> Starting x…")
      expect(described_class.init_line({ type: :plugin_init_finished, bundle: "mcp", label: "Starting x", ok: true,
                                          summary: "x ready, 2 tools" })).to eq("mcp> ✓ x ready, 2 tools")
      expect(described_class.init_line({ type: :plugin_init_finished, bundle: "b", label: "Indexing", ok: true }))
        .to eq("b> ✓ Indexing: done")
      expect(described_class.init_line({ type: :plugin_init_finished, bundle: "b", label: "x", ok: false, error: "e" })).to be_nil
    end
  end
end
