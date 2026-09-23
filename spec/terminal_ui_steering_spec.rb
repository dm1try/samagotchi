# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require_relative "support/recording_surface"

# REPL steering: a line submitted at the open prompt while a turn runs.
RSpec.describe Samagotchi::TerminalUI, "steering" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:surface) { RecordingSurface.new }
  let(:agent) { described_class.new(mode: :assist, client: client, surface: surface) }
  let(:engine) { agent.instance_variable_get(:@engine) }
  let(:session) { instance_double(Samagotchi::Session, messages: []) }
  let(:repl_input) { Samagotchi::TerminalUI::ReplInput.new(prompt: -> { "> " }, read: ->(*) {}, surface: surface) }
  let(:result) { Samagotchi::KernelLoop::Result.new(output: "ok", conversation: [], tool_activity: []) }

  before do
    agent.instance_variable_set(:@pending_input_queue, Samagotchi::PendingInputQueue.new)
    agent.instance_variable_set(:@repl_input, repl_input)
    allow(agent).to receive(:persist_recent_history)
  end

  it "merges a line submitted during the turn at the next iteration boundary" do
    drained = nil
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      repl_input << [:line, "also check #mem"]
      drained = pending_input.call
      result
    end

    agent.send(:run_engine_turn, session, "go")

    expect(drained).to eq([agent.send(:normalize_model_input, "also check #mem")])
    expect(agent).to have_received(:persist_recent_history).with("also check #mem")
    expect(repl_input.pop(timeout: 0)).to be_nil
  end

  it "runs a line that came after the last iteration as the next turn" do
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      pending_input.call
      repl_input << [:line, "too late to merge"]
      result
    end

    agent.send(:run_engine_turn, session, "go")

    expect(repl_input.pop(timeout: 0)).to eq([:line, "too late to merge"])
  end

  it "leaves a line sent after Ctrl-C (even a command) for after the turn" do
    allow(engine).to receive(:run_turn) do |*, cancel_controller:, **|
      cancel_controller.cancel!(:ctrl_c)
      repl_input << [:line, "next"] << [:line, "!ls"]
      result
    end

    agent.send(:run_engine_turn, session, "go")

    expect(Array.new(2) { repl_input.pop(timeout: 0).last }).to eq(["next", "!ls"])
  end

  it "runs /stats at once and puts another command back into the prompt, busy" do
    reader = double("reader", prefill_next: nil)
    repl_input.instance_variable_set(:@reader, reader)
    allow(engine).to receive(:stats_snapshot).and_return({})
    allow(agent).to receive(:format_session_metrics).and_return("turns: 1")
    allow(engine).to receive(:run_turn) do
      repl_input << [:line, "/stats"] << [:line, "!ls"]
      result
    end

    agent.send(:run_engine_turn, session, "go")

    expect(surface.lines).to include("\nmodel> session stats:\nturns: 1", "busy: wait for the turn to end")
    expect(reader).to have_received(:prefill_next).with("!ls")
    expect(repl_input.pop(timeout: 0)).to be_nil
  end

  %w[Ctrl-D exit].each do |key|
    it "exits after the turn on #{key}, and says so" do
      line = key == "exit" ? "/exit" : nil
      allow(engine).to receive(:run_turn) do
        repl_input << [:line, line]
        result
      end

      agent.send(:run_engine_turn, session, "go")

      expect(surface.lines).to include("(exits after this turn; Ctrl-C cancels it)")
      expect(agent.instance_variable_get(:@exit_after_turn)).to be(true)
      expect(repl_input.pop(timeout: 0)).to be_nil
    end
  end

  it "ends the loop after the turn instead of reading on" do
    allow(agent).to receive(:poll_input_with_reminder_check).and_return("go", "never read", nil)
    allow(agent).to receive(:run_input_line) { agent.instance_variable_set(:@exit_after_turn, true) }
    allow(agent).to receive(:drain_pending_question?)

    agent.send(:run_assist_loop, session: instance_double(Samagotchi::Session, id: "s1", "messages=": nil), messages: [])

    expect(agent).to have_received(:run_input_line).once
    expect(surface.lines.last).to include("Continue session: chi --resume s1")
  end

  it "still runs the lines sent before Ctrl-D, then exits" do
    agent.instance_variable_set(:@exit_after_turn, true)
    repl_input << [:line, "sent before"]
    allow(agent).to receive(:run_input_line)
    allow(agent).to receive(:poll_input_with_reminder_check)

    agent.send(:run_assist_loop, session: instance_double(Samagotchi::Session, id: "s1", "messages=": nil), messages: [])

    expect(agent).to have_received(:run_input_line).once.with(anything, "sent before")
    expect(agent).not_to have_received(:poll_input_with_reminder_check)
  end
end
