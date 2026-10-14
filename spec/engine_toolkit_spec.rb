# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"
require "samagotchi/llm/chat_loop"

# A session's toolkit reaches the Registry at a turn's start only, beside
# the plugins' staged tool sets: a change made while a turn runs (or
# between turns) is what the next turn declares, never the running one.
RSpec.describe Samagotchi::Engine, "toolkit" do
  include_context "thinking off"

  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:events) { [] }
  let(:result) do
    Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [{ role: "user", content: "hi" }, { role: "model", content: "ok" }],
                                     exhausted: false, pending_tool_calls: false, tool_activity: [])
  end

  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def engine = @engine ||= described_class.new(client: client, kernel: kernel, profile: "gemma4")

  def session(toolkit = nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.toolkit = toolkit
    end
  end

  def turn(sess) = engine.run_turn(sess, "hi", on_event: ->(event) { events << event })

  it "declares the session's toolkit from its first turn, and a change only from the next turn's start" do
    seen = []
    sess = session(Samagotchi::Toolkit.new(name: "lean"))
    allow(kernel).to receive(:run) do
      seen << kernel.tools.names
      # A /toolkit change while the turn runs: this turn keeps its tools.
      sess.toolkit = sess.toolkit.adding("delegate") if seen.size == 1
      seen << kernel.tools.names
      result
    end

    turn(sess)
    turn(sess)

    expect(seen[0]).not_to include("delegate")
    expect(seen[1]).to eq(seen[0])
    expect(seen[2] - seen[0]).to eq(["delegate"])
    expect(engine.system_prompt).to include("Not declared in this session (toolkit lean)")
  end

  it "declares every tool for a session without one (full), and the prompt has no not-loaded line" do
    allow(kernel).to receive(:run).and_return(result)
    turn(session)
    expect(kernel.tools.toolkit).to be_nil
    expect(kernel.tools.names).to eq(Samagotchi::Tools::Builtins.default.names)
    expect(engine.system_prompt).not_to include("Not loaded")
  end

  it "falls back to full for a name it can't resolve, says so once, and keeps the saved name" do
    allow(kernel).to receive(:run).and_return(result)
    sess = session(Samagotchi::Toolkit.new(name: "coordinator"))
    turn(sess)
    turn(sess)

    warnings = events.select { |e| e[:type] == :guardrail_warning && e[:label] == "toolkit" }
    expect(warnings.map { |e| e[:message] }).to eq(["coordinator: no toolkit named coordinator; this session declares " \
                                                     "every tool (full) until it resolves"])
    expect(kernel.tools.names).to include("delegate")
    expect(sess.toolkit.name).to eq("coordinator")
  end

  it "reads config's toolkit.kits once per process: an edit doesn't change a live session's tools" do
    kits = { "mine" => { "base" => "lean" } }
    allow(Samagotchi::Toolkit).to receive(:config_kits) { kits }
    allow(kernel).to receive(:run).and_return(result)
    sess = session(Samagotchi::Toolkit.new(name: "mine"))
    turn(sess)
    expect(kernel.tools.names).not_to include("delegate")
    kits = { "mine" => { "base" => "full" } }
    turn(sess)
    expect(kernel.tools.names).not_to include("delegate")
  end

  # B3: the request bytes of a full session with its plugins loaded (no MCP
  # server) are the chat_tools.json snapshot's, with no not-loaded line and
  # no chip: the tool index declares nothing there.
  it "sends full's tools unchanged with the plugins loaded and no MCP" do
    expect_any_instance_of(Samagotchi::Tools::ToolIndex).to receive(:declare).and_call_original
    allow(kernel).to receive(:run).and_return(result)
    turn(session)
    chat_tools = JSON.pretty_generate(Samagotchi::LLM::ChatLoop.new(kernel: kernel).tool_definitions) + "\n"

    expect(chat_tools).to eq(File.read(File.expand_path("fixtures/prompt_snapshots/chat_tools.json", __dir__)))
    expect(engine.system_prompt).not_to include("Not loaded", "Not declared", "find_tools")
    expect(engine.toolkit_summary).to be_nil
  end

  it "names the call_tool route alone when the toolkit removes find_tools" do
    allow(kernel).to receive(:run).and_return(result)
    turn(session(Samagotchi::Toolkit.new(name: "lean", remove: ["find_tools"])))
    expect(engine.system_prompt).to include("delegate_result. Call one with call_tool(tool: \"chi/<name>\", args: {…}). " \
                                            "Removed (toolkit lean): find_tools. Only the user can load it")
  end

  it "declares find_tools and call_tool on lean, with the plugins loaded and no MCP" do
    allow(kernel).to receive(:run).and_return(result)
    turn(session(Samagotchi::Toolkit.new(name: "lean")))
    expect(kernel.tools.names).to include("find_tools", "call_tool")
    expect(kernel.tools["find_tools"].schema[:description]).to include("- chi: chi's own tools not declared")
  end
end
