# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_bundle"

# What the model sees of the mcp bundle's tools, as golden texts
# (spec/fixtures/mcp/goldens; UPDATE_MCP_GOLDENS=1 rewrites them): the
# search tool's description, searches, the call tool's errors, a call's
# guardrail targets and /mcp. Two servers: fake, cached (a session before
# saved its tools), and slow, on its first run and still starting.
RSpec.describe "The mcp bundle's texts" do
  include_context "the mcp bundle in an Engine"

  let(:tools_file) { File.join(tmpdir, "tools").tap { |f| File.write(f, %w[echo navigate_page take_screenshot bad].join("\n")) } }
  let(:fake) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_TOOLS" => tools_file } } }
  let(:slow) { { "command" => MCP_FAKE_COMMAND, "env" => { "FAKE_MCP_MODE" => "slow", "FAKE_MCP_DELAY" => "3" } } }

  def golden_dir = File.expand_path("../../fixtures/mcp/goldens", __dir__)

  # +actual+ is the fixture's text.
  def expect_golden(name, actual)
    path = File.join(golden_dir, "#{name}.txt")
    actual = actual.to_s
    if ENV["UPDATE_MCP_GOLDENS"] == "1"
      FileUtils.mkdir_p(golden_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  def mcp_card
    cards = []
    handle = engine.subscribe(observer: ->(e) { cards << e if e[:type] == :card })
    commands = Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                               default_model: "Gemma-4B-it", registry: engine.command_registry)
    engine.running_anytime { commands.run("/mcp") }
    engine.unsubscribe(handle: handle)
    cards.last[:body]
  end

  def find_tool = tools.entries.find { |entry| entry.schema[:description].to_s.start_with?("Search the tools") }
  def call_entry = tools.entries.find { |entry| entry.label == "mcp" }

  before do
    engine # fake's first run: its tools are cached
    @engine.shutdown
    servers["slow"] = slow
    settings["startup_timeout"] = 10
    @engine = Samagotchi::Engine.new(client: client)
    @engine.start_init_tasks!
  end

  it "describes the servers in the search tool, from the cache and the config" do
    expect_golden("find_description", find_tool.schema[:description])
    expect_golden("schemas", JSON.pretty_generate([find_tool.schema, call_entry.schema]))
  end

  it "answers searches while a server is starting" do
    expect_golden("find_hit", find("screenshot"))
    expect_golden("find_miss", find("zebra"))
    expect_golden("find_empty", find(""))
    expect_golden("find_server", find("page", "fake"))
    expect_golden("find_unknown_server", find("echo", "nope"))
    expect_golden("find_refused", find("inputschema object"))
    expect_golden("find_starting", find("echo"))
  end

  it "lists the servers in /mcp while one is starting" do
    expect_golden("mcp_listing", mcp_card)
  end

  it "answers a call's errors" do
    expect_golden("call_errors", [
      mcp("echo_text"), handle(call_entry.name, { "tool" => "zebra" }), mcp("bad"),
      handle(call_entry.name, { "tool" => "fake/echo", "args" => "hello" })
    ].join("\n---\n"))
  end

  it "gives guardrails the call's targets and previews it" do
    targets = call_entry.targets
    calls = [{ "tool" => "fake/echo", "args" => { "text" => "hi" } }, { "tool" => "mcp_fake_echo" },
             { "tool" => "fake/nope" }, { "tool" => "slow/echo", "args" => { "text" => "x" } }, { "tool" => "nope" }]
    lines = calls.map do |args|
      call = { name: call_entry.name, args: args }
      "#{JSON.generate(args)} → #{targets.call(call).inspect} | #{call_entry.preview.call(call)}"
    end
    find_call = { name: find_tool.name, args: { "query" => "echo", "server" => "fake" } }
    lines << "find → #{find_tool.preview.call(find_call)}"
    expect_golden("call_targets", lines.join("\n"))
  end

  it "waits for the starting server on a call of its tool, then searches it" do
    expect(mcp("echo", { "text" => "waited" }, server: "slow")).to eq("echo: waited")
    expect_golden("find_started", find("echo"))
  end
end
