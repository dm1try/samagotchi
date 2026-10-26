# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"
require "samagotchi/llm/chat_loop"
require "support/fake_provider_server"

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

  it "warns once when no declare-time group matches a selector, even if a source later publishes that name" do
    allow(Samagotchi::Toolkit).to receive(:config_kits)
      .and_return("web" => { "base" => "full", "groups" => ["late"] })
    index = engine.instance_variable_get(:@tool_index)
    source = index.source(label: "spec", call: ->(*) { "ok" }, acts_as: ->(group, name) { "mcp_#{group}_#{name}" })
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "known")])
    index.add(source)
    index.declare(engine.tools)
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "known"),
                    Samagotchi::Tools::ToolIndex::Group.new(name: "late")])
    allow(kernel).to receive(:run).and_return(result)
    sess = session(Samagotchi::Toolkit.new(name: "web"))

    turn(sess)
    turn(sess)

    warnings = events.select { |event| event[:type] == :guardrail_warning && event[:label] == "toolkit" }
    expect(warnings.map { |event| event[:message] }).to eq(["web: group selector \"late\" matches no group declared at load"])
    expect(engine.tools.index.groups).to eq(["known"])
    expect(engine.tools.index.groups).not_to include("late")
  end

  it "finds the first resolvable kit that reaches a group, skipping kits that don't or can't resolve" do
    kit = Samagotchi::Toolkit::Kit
    binding = engine.instance_variable_get(:@toolkit_binding)

    expect(binding.reaching_kit("fs")).to eq("full")
    allow(binding).to receive(:kits).and_return(
      "a_closed" => kit.new(name: "a_closed", tools: [], groups: []),
      "b_broken" => kit.new(name: "b_broken", base: "nowhere", groups: ["fs"]),
      "c_fs" => kit.new(name: "c_fs", tools: [], groups: ["fs"]),
      "d_fs" => kit.new(name: "d_fs", tools: [], groups: ["fs"])
    )
    expect(binding.reaching_kit("fs")).to eq("c_fs")
    expect(binding.reaching_kit("other")).to be_nil
  end

  it "names the user's own kit before a built-in that also reaches the group" do
    kit = Samagotchi::Toolkit::Kit
    binding = engine.instance_variable_get(:@toolkit_binding)
    builtins = Samagotchi::Toolkit::BUILTIN_KITS.dup
    allow(binding).to receive(:kits).and_return(builtins.merge("web" => kit.new(name: "web", base: "lean", groups: ["fs"])))

    expect(binding.reaching_kit("fs")).to eq("web")
  end

  it "resolves a saved kit name against each worker's toolkit.kits snapshot" do
    kits = { "mine" => { "base" => "lean", "groups" => ["chrome"] } }
    allow(Samagotchi::Toolkit).to receive(:config_kits) { kits }
    allow(kernel).to receive(:run).and_return(result)
    sess = session(Samagotchi::Toolkit.new(name: "mine"))
    turn(sess)
    expect(kernel.tools.names).not_to include("delegate")
    expect(kernel.tools.toolkit.groups).to eq(["chrome"])
    kits = { "mine" => { "base" => "lean", "groups" => ["postgres"] } }
    turn(sess)
    expect(kernel.tools.names).not_to include("delegate")

    next_kernel = test_kernel(client: client)
    allow(next_kernel).to receive(:run).and_return(result)
    next_engine = described_class.new(client: client, kernel: next_kernel, profile: "gemma4")
    next_engine.run_turn(sess, "hi")

    expect(next_kernel.tools.toolkit.groups).to eq(["postgres"])
    expect(sess.toolkit).to eq(Samagotchi::Toolkit.new(name: "mine"))
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

  describe "a kit's prompt text" do
    let(:kits) do
      { "terse" => { "base" => "lean", "prompt" => "- Be concise in your responses" },
        "brief" => { "base" => "lean", "prompt" => "- Be brief" },
        "loud" => { "prompt" => "- Say more" } }
    end

    before do
      allow(Samagotchi::Toolkit).to receive(:config_kits) { kits }
      allow(kernel).to receive(:run).and_return(result)
    end

    it "sits after the appended files, right before the memory indexes, from the session's first turn" do
      turn(session(Samagotchi::Toolkit.new(name: "terse")))
      prompt = engine.system_prompt
      expect(prompt).to include("\n- Be concise in your responses\nProject memories:")
      expect(prompt.index("- Be concise")).to be > prompt.index("Not declared in this session (toolkit terse)")
    end

    it "is absent on a kit without one, and on full" do
      turn(session(Samagotchi::Toolkit.new(name: "lean")))
      expect(engine.system_prompt).not_to include("- Be concise", "- Be brief")
    end

    it "changes with /toolkit at the next turn's start, not mid-turn, also when the tools stay the same" do
      sess = session(Samagotchi::Toolkit.new(name: "terse"))
      seen = []
      allow(kernel).to receive(:run) do
        seen << engine.system_prompt
        sess.toolkit = Samagotchi::Toolkit.new(name: "brief") if seen.size == 1
        seen << engine.system_prompt
        result
      end

      turn(sess)
      tools = kernel.tools.names
      turn(sess)

      expect(seen[0]).to include("- Be concise in your responses")
      expect(seen[1]).to eq(seen[0])
      expect(seen[2]).to include("- Be brief")
      expect(seen[2]).not_to include("- Be concise")
      expect(kernel.tools.names).to eq(tools)
    end

    it "puts the next turn's kit prompt in /stats' snapshot (kit_prompt), none on a kit without one or on full" do
      engine.session = session(Samagotchi::Toolkit.new(name: "terse"))
      expect(engine.stats_snapshot[:kit_prompt]).to eq({ kit: "terse", tokens: 8 })
      engine.session = session(Samagotchi::Toolkit.new(name: "lean"))
      expect(engine.stats_snapshot).not_to have_key(:kit_prompt)
      engine.session = session
      expect(engine.stats_snapshot).not_to have_key(:kit_prompt)
    end

    it "keeps a kit on full's tools with a prompt declaring what full does, with no not-loaded line" do
      turn(session(Samagotchi::Toolkit.new(name: "loud")))
      expect(kernel.tools.toolkit&.name).to eq("loud")
      expect(kernel.tools.names).to eq(Samagotchi::Tools::Builtins.default.names)
      expect(engine.system_prompt).to include("\n- Say more\nProject memories:")
      expect(engine.system_prompt).not_to include("Not loaded", "Not declared")
    end
  end

  it "tells a delegate the kits it can start a child on (PeerView#toolkit_names)" do
    allow(Samagotchi::Toolkit).to receive(:config_kits).and_return("coding" => { "base" => "child" })
    expect(Samagotchi::Engine::PeerView.new(engine).toolkit_names).to eq(%w[full lean child review coding])
  end

  it "declares find_tools and call_tool on lean, with the plugins loaded and no MCP" do
    allow(kernel).to receive(:run).and_return(result)
    turn(session(Samagotchi::Toolkit.new(name: "lean")))
    expect(kernel.tools.names).to include("find_tools", "call_tool")
    expect(kernel.tools["find_tools"].schema[:description]).to include("- chi: chi's own tools not declared")
  end

  # The host that loads tools is the one the turn runs on after its
  # before_turn hooks (lean tools P2c): TurnSettings#loads_tools is set in
  # #generate, from the final model's adapter.
  describe "loads_tools" do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }
    let(:registry) do
      Samagotchi::HostRegistry.new(hosts_config: {
        "box" => { host: "box.test", port: 8080 },
        "ant" => { url: server.root_url, api: :anthropic, remote: true },
        "oai" => { url: server.base_url, api: :openai, remote: true }
      })
    end

    after { server.stop }

    def loads_after_switch(from, to)
      engine = described_class.new(host_registry: registry, model_name: from)
      sess = Samagotchi::Session.new_session(mode: "assist", model_name: from, working_directory: Dir.pwd)
      engine.store_model!(sess)
      engine.session = sess
      kernel = engine.instance_variable_get(:@kernel)
      seen = []
      allow(kernel).to receive(:turn_settings=).and_wrap_original do |original, value|
        seen << value.loads_tools
        original.call(value)
      end
      engine.register_hook(:before_turn) { |_event| engine.switch_model!(to) }
      server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("text_stream.hand-written.sse", api: "anthropic"))
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
      allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
      engine.run_turn(sess, "hi")
      seen.last
    end

    it "is true when a hook switched the turn to a Messages host, false when it switched away" do
      expect(loads_after_switch("oai:gpt-x", "ant:claude-x")).to be(true)
      expect(loads_after_switch("ant:claude-x", "oai:gpt-x")).to be(false)
    end
  end
end
