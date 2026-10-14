# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session_commands"
require "samagotchi/toolkit_command"
require "samagotchi/turn_flow"
require "support/test_kernel"

# /toolkit: lists what the next turn declares, changes the session's
# toolkit (saved at once, applied at the next turn's start), and asks first
# once the session has a model reply.
RSpec.describe Samagotchi::ToolkitCommand do
  let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:saved) { [] }
  let(:command) { described_class.new(engine: engine, save: ->(s) { saved << s }) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    engine.session = session
  end

  it "lists the declared tools with tokens, the toolkit, and what it leaves out" do
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    output, changed, ask = command.run("")

    expect([changed, ask]).to eq([false, nil])
    lines = output.lines.map(&:chomp)
    expect(lines[0]).to eq("toolkit: lean (applies at the next turn's start)")
    expect(lines[1]).to match(/\A  declared \(16, ~\d\.\dk tokens\): execute ~\d+, read ~\d+/)
    expect(lines[2]).to eq("  not loaded: register_reminder, cancel_reminder, list_reminders, list_sessions, send_note, " \
                           "delegate, delegate_result")
    expect(lines[3]).to eq("  toolkits: full, lean, child; /toolkit [NAME | add TOOL | remove TOOL] changes it")
    expect(saved).to be_empty
  end

  it "puts the session on another toolkit, or adds and removes a tool, saved at once" do
    output, changed, = command.run("lean")
    expect(changed).to be(true)
    expect(session.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean"))
    expect(output).to end_with("From the next turn's start (a running turn keeps its tools).")

    command.run("add delegate")
    command.run("remove web_fetch")
    expect(session.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean", add: ["delegate"], remove: ["web_fetch"]))
    expect(saved.size).to eq(3)
  end

  it "says so when nothing the prompt carries changes, and saves nothing" do
    output, changed, = command.run("full")
    expect(changed).to be(false)
    expect(output).to end_with("(no change to what the next turn declares)")
    # full declares delegate already: no "full +delegate".
    expect(command.run("add delegate")[1]).to be(false)
    expect(session.toolkit).to be_nil
    expect(saved).to be_empty
    expect(engine.toolkit_summary).to be_nil
  end

  it "asks first for a kit that declares the same tools under another name (the not-loaded line names it)" do
    allow(Samagotchi::Toolkit).to receive(:config_kits).and_return("mykit" => { "base" => "lean" })
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    allow(engine).to receive(:history?).and_return(true)
    output, changed, ask = command.run("mykit")
    expect(changed).to be(false)
    expect(ask&.line).to eq("/toolkit mykit --yes")
    expect(output).to start_with("Switching to mykit declares the same tools under its own name.")
  end

  # D12: what the prompt carries includes the reachable and the removed
  # tools, so a remove of a tool lean leaves out (reachable) is a change.
  it "saves a remove of a tool the toolkit leaves out (it becomes unreachable), and an add after it declares it" do
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    _, changed, = command.run("remove delegate")
    expect(changed).to be(true)
    expect(session.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean", remove: ["delegate"]))
    expect(engine.toolkit_explained.removed).to eq(["delegate"])
    expect(engine.toolkit_explained.reachable).not_to include("delegate")

    command.run("add delegate")
    expect(session.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean", add: ["delegate"]))
    expect(engine.toolkit_explained.declared.map(&:name)).to include("delegate")
    command.run("remove delegate")
    expect(session.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean", remove: ["delegate"]))
    expect(saved.size).to eq(3)
  end

  it "asks first for that remove once the session has a model reply" do
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    allow(engine).to receive(:history?).and_return(true)
    _, changed, ask = command.run("remove delegate")
    expect(changed).to be(false)
    expect(ask&.line).to eq("/toolkit remove delegate --yes")
  end

  it "refuses an unknown toolkit or tool, keeping a tool's case" do
    expect { command.run("nope") }.to raise_error(ArgumentError, "no toolkit named nope (toolkits: full, lean, child)")
    expect { command.run("add Delegate") }.to raise_error(ArgumentError, "no tool named Delegate in this session")
    expect { command.run("add") }.to raise_error(ArgumentError, /needs a tool name/)
    engine.tools.register("Mixed_Tool", schema: { name: "Mixed_Tool" }, handler: ->(*) {}, source: "mcp")
    command.run("lean")
    command.run("remove Mixed_Tool --yes")
    expect(session.toolkit.remove).to eq(["Mixed_Tool"])
  end

  it "asks first once the session has a model reply, and --yes applies it" do
    allow(engine).to receive(:history?).and_return(true)
    output, changed, ask = command.run("lean")

    expect(changed).to be(false)
    expect(session.toolkit).to be_nil
    expect(output).to start_with("Switching to lean declares call_tool, find_tools; leaves out register_reminder, cancel_reminder")
    expect(ask).to eq(Samagotchi::CacheConfirm::Confirm.new(line: "/toolkit lean --yes",
                                                            text: "Nothing changed yet: send `/toolkit lean --yes` to apply."))
    expect(command.run("lean --yes")[1]).to be(true)
    expect(command.run("add delegate", confirm: false)[1]).to be(true)
  end

  describe "in SessionCommands" do
    let(:commands) do
      Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: "m",
                                      registry: engine.command_registry, save: ->(s) { saved << s })
    end

    it "shows mid-turn, queues a change, and reports :toolkit as changed" do
      expect(engine.command_registry.mid_turn("/toolkit")).to eq(:anytime)
      expect(engine.command_registry.mid_turn("/toolkit lean")).to eq(:queue)
      expect(commands.run("/toolkit lean").changed).to eq([:toolkit])
    end
  end
end
