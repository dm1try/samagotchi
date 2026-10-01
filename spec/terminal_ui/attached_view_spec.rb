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
         { type: :generation_chunk, iteration: 1, content: "Let me look." },
         { type: :tool_dispatch_started, iteration: 1 },
         { type: :tool_call_started, iteration: 1, call_index: 0, tool: "read" },
         { type: :tool_call_completed, iteration: 1, call_index: 0, tool: "read", activity: activity },
         { type: :generation_started, iteration: 2 },
         { type: :generation_completed, iteration: 2 },
         { type: :turn_completed, turn_summary: { tool_activity: [activity], output: "It says hi.", resumable: false,
                                                   context_status: { est_pct: 7, bucket: "low" } } })

    # Whole seconds apart: the spinner (4 frames a second) is on "|" each time.
    expect(screen.statuses.compact).to eq(["| thinking…", "| thinking · Let me look.", "| running read…", "| thinking…"])
    expect(screen.statuses.last).to be_nil
    expect(screen.lines.size).to eq(2)
    expect(screen.lines.first).to include("reading file (read path=a): ok")
    expect(screen.lines.last).to eq("It says hi.")
    expect(view.context_status).to eq(est_pct: 7, bucket: "low")
  end

  it "turns the activity row for a plugin's init task until it ends, between turns and while a turn waits" do
    view.init_started({ bundle: "mcp", id: "mcp-1", label: "Starting chrome" })
    expect(screen.statuses.last).to eq("| mcp: Starting chrome…")
    feed({ type: :turn_started }, { type: :plugin_init_wait, tasks: [{ bundle: "mcp", id: "mcp-1", label: "Starting chrome" }] })
    expect(screen.statuses.last).to eq("| mcp: Starting chrome…")
    feed({ type: :generation_started, iteration: 1 })
    expect(screen.statuses.last).to eq("| thinking…")
    view.finish_thinking_spinner
    expect(screen.statuses.last).to eq("| mcp: Starting chrome…")
    view.init_finished({ id: "mcp-1" })
    expect(screen.statuses.last).to be_nil
  end

  it "cuts a long sentence to the terminal width" do
    feed({ type: :generation_started, iteration: 1 },
         { type: :generation_chunk, iteration: 1, content: "#{"a" * 60}END. " })

    status = screen.statuses.last
    expect(status).to start_with("| thinking · aaa").and end_with("a…")
    expect(status.length).to eq(39)
  end

  describe "the sentence" do
    before { feed({ type: :generation_started, iteration: 1 }) }

    # The row without its spinner frame.
    def row = screen.statuses.last[2..]

    def chunk(**fields)
      now[0] += 0.5
      view.generation_feedback_chunk(fields)
    end

    it "is the newest complete one, changing at most once per dwell" do
      chunk(content: "TURN: reading the config\nFirst I read it")
      expect(row).to eq("thinking · reading the config")
      chunk(content: ". Then 1. ")
      chunk(content: "Then **the** `log`. And")
      expect(row).to eq("thinking · reading the config")
      now[0] += 0.5
      view.tick
      expect(row).to eq("thinking · Then the log.")
    end

    it "comes from the split lanes when the chunk has them, labelled by its lane" do
      chunk(content: "<think>raw", thinking: "Check it.\n", text: "")
      expect(row).to eq("thinking · Check it.")
      now[0] += 2
      chunk(content: "</think>Hi", thinking: "", text: "Here it is.\n")
      expect(row).to eq("writing · Here it is.")
    end

    it "picks up a turn joined mid-way" do
      view.resume(tail: "<think>Reading it. Now", lane: :thinking)
      expect(row).to eq("thinking · Reading it.")
    end

    it "starts over with each generation" do
      chunk(content: "Done. ")
      view.generation_feedback_finished
      view.generation_feedback_started
      expect(row).to eq("thinking…")
    end
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

    it "says which retry it is, when, and what failed" do
      view.generation_feedback_started
      view.generation_feedback_retrying(attempt: 1, max_retries: 3, next_delay: 0.5, error_class: "Errno::ECONNREFUSED")
      expect(screen.statuses.last).to eq("| retrying (1/3 in 0.5s): Errno::ECONNREFUSED")

      view.generation_feedback_retrying(attempt: 2)
      expect(screen.statuses.last).to eq("| retrying (attempt 2)")
    end

    it "stops counting at the first chunk, and again after a retry" do
      view.generation_feedback_started
      now[0] = 5.0
      view.generation_feedback_chunk(content: "Hi.")
      now[0] = 9.0
      view.tick
      expect(screen.statuses.last).to eq("| thinking · Hi.")

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

    # Poll for +condition+ instead of sleeping a fixed time: a slow runner
    # gets as long as it needs, up to +timeout+ seconds.
    def wait_until(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      yield
    end

    it "runs a ticker thread while the slot is shown, which ends with it" do
      real = described_class.new(screen, tick_interval: 0.02)
      real.generation_feedback_started
      ticker = real.instance_variable_get(:@ticker)
      expect(wait_until { screen.statuses.size > 3 }).to be(true)

      real.finish_thinking_spinner
      expect(wait_until { !ticker.alive? }).to be(true)
      after = screen.statuses.size
      sleep 0.08
      expect(screen.statuses.size).to eq(after)
      real.stop
    end

    it "runs no ticker thread under the suite's defaults, as AttachedLoop builds it" do
      default = described_class.new(screen)
      default.generation_feedback_started
      expect(default.instance_variable_get(:@ticker)).to be_nil
      expect(screen.statuses.last).to end_with("thinking…")
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

  describe "the tool tally row" do
    def tool_call(iteration, tool, params: "command=x", status: "ok")
      activity = { action: "running command", tool: tool, params: params, status: status }
      feed({ type: :tool_call_started, iteration: iteration, call_index: 1, tool: tool, params: params },
           { type: :tool_call_completed, iteration: iteration, call_index: 1, tool: tool, activity: activity })
    end

    it "adds a second row from the turn's 3rd tool call" do
      feed({ type: :turn_started }, { type: :generation_started, iteration: 1 })
      tool_call(1, "execute")
      feed({ type: :generation_started, iteration: 2 })
      tool_call(2, "read_file", params: "path=a", status: "error")
      feed({ type: :generation_started, iteration: 3 })
      expect(screen.slots[:activity].size).to eq(1)

      feed({ type: :tool_call_started, iteration: 3, call_index: 1, tool: "execute", params: "command=rspec" })
      expect(screen.slots[:activity]).to eq(["| running execute…",
                                             "3 tool calls (1 failed) · execute ×2 ·…"])
      expect(screen.slots[:activity].last.length).to eq(39)
    end

    it "keeps counting across a merge and starts over with the next turn" do
      feed({ type: :turn_started })
      3.times { |i| tool_call(i + 1, "execute") }
      feed({ type: :pending_input_merged, count: 1, content: "also" },
           { type: :generation_started, iteration: 4 })
      expect(screen.slots[:activity].last).to start_with("3 tool calls")

      feed({ type: :turn_completed, turn_summary: { tool_activity: [], output: "done", resumable: false } })
      expect(screen.slots[:activity]).to be_nil
      feed({ type: :turn_started }, { type: :generation_started, iteration: 1 })
      expect(screen.slots[:activity]).to eq(["| thinking…"])
    end

    it "seeds the tally from a joined turn's snapshot parts" do
      parts = [
        { kind: "tool", iteration: 1, call_index: 1, tool: "execute", params: "command=a", status: "ok" },
        { kind: "tool", iteration: 2, call_index: 1, tool: "execute", params: "command=b", status: "ok" },
        { kind: "tool", iteration: 3, call_index: 1, tool: "read_file", params: "path=c", status: "running" }
      ]
      view.resume(tool: "read_file", parts: parts)
      expect(screen.slots[:activity]).to eq(["| running read_file…",
                                             "3 tool calls · execute ×2 · read_file …"])

      # The running call's completion doesn't count twice.
      feed({ type: :tool_call_completed, iteration: 3, call_index: 1, tool: "read_file",
             activity: { action: "reading file", tool: "read_file", params: "path=c", status: "ok" } },
           { type: :generation_started, iteration: 4 })
      expect(screen.slots[:activity].last).to start_with("3 tool calls · ")
    end
  end
end
