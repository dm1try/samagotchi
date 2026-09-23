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

  it "leaves Ctrl-D, commands, exit and a line sent after Ctrl-C for after the turn" do
    allow(engine).to receive(:run_turn) do |*, cancel_controller:, **|
      repl_input << [:line, nil] << [:line, "/stats"] << [:line, "!ls"] << [:line, "exit"]
      cancel_controller.cancel!(:ctrl_c)
      repl_input << [:line, "next"]
      result
    end

    agent.send(:run_engine_turn, session, "go")

    expect(Array.new(5) { repl_input.pop(timeout: 0).last }).to eq([nil, "/stats", "!ls", "exit", "next"])
  end
end
