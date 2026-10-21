# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/plugin/context"
require "samagotchi/context_note"
require "samagotchi/turn_note"
require "samagotchi/toolkit"
require_relative "support/fake_provider_server"

# A plugin's ctx.load_tools (lean tools P3): staged, then appended to a
# turn's messages as a system tool_change entry, which a Messages host gets
# as a tool_addition (beta inline-tools); the model calls the tool by name.
RSpec.describe "ctx.load_tools" do
  around do |example|
    FakeProviderServer.without_webmock do
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end
  end

  let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "ant" => { url: server.root_url, api: :anthropic, remote: true },
      "oai" => { url: server.base_url, api: :openai, remote: true }
    })
  end
  let(:ran) { [] }

  after { server.stop }

  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  def engine_on(model)
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: model)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: Dir.pwd)
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    engine.store_model!(session)
    engine.session = session
    engine.instance_variable_get(:@tools)["delegate"].handler = lambda { |call, _kctx|
      ran << call[:content]
      "started child"
    }
    [engine, session]
  end

  def ctx(engine) = Samagotchi::Plugin::Context.new(bundle: "loader", label: "plugin.rb (bundle loader)", settings: {},
                                                    host: engine.send(:plugin_host))

  def sse(*events) = events.map { |event| "event: #{event[:type]}\ndata: #{JSON.generate(event)}\n\n" }.join

  def tool_use(id, name, input)
    sse({ type: "message_start", message: { id: "msg_#{id}", type: "message", role: "assistant", model: "m", content: [],
                                            usage: { input_tokens: 10, output_tokens: 1 } } },
        { type: "content_block_start", index: 0, content_block: { type: "tool_use", id: id, name: name, input: {} } },
        { type: "content_block_delta", index: 0, delta: { type: "input_json_delta", partial_json: JSON.generate(input) } },
        { type: "content_block_stop", index: 0 },
        { type: "message_delta", delta: { stop_reason: "tool_use" }, usage: { output_tokens: 5 } },
        { type: "message_stop" })
  end

  def text_reply = FakeProviderServer.fixture("text_stream.hand-written.sse", api: "anthropic")

  def requests = server.requests.select { |r| r.path == "/v1/messages" }

  def changes_in(body) = body["messages"].select { |m| m["role"] == "system" }

  it "loads delegate from before_turn: the entry follows the user message, the model calls it by name" do
    engine, session = engine_on("ant:claude-x")
    loader = ctx(engine)
    staged = []
    engine.register_hook(:before_turn) { |_e| staged << loader.load_tools(%w[delegate read nope]) }
    server.enqueue("/v1/messages", sse: tool_use("toolu_d", "delegate", { task: "look around" }))
    server.enqueue("/v1/messages", sse: text_reply)

    engine.run_turn(session, "hand it off")

    expect(staged).to eq([%w[delegate]])
    expect(ran).to eq(["look around"])
    first, second = requests.map(&:json)
    expect(changes_in(first)).to eq([{ "role" => "system", "content" => [
      { "type" => "tool_addition", "tool" => { "type" => "tool_reference", "name" => "delegate" } }
    ] }])
    expect(first["messages"].map { |m| m["role"] }).to eq(%w[user system])
    expect(requests.map { |r| r.header("anthropic-beta") }).to eq(["inline-tools-2026-09-15"] * 2)
    # Append-only: the second request extends the first.
    expect(second["messages"].first(2)).to eq(first["messages"].map { |m| JSON.parse(JSON.generate(m).gsub(/,"cache_control":\{[^}]*\}/, "")) })
    entry = session.messages.find { |m| m[:kind] == "tool_change" }
    expect(entry).to include(role: "system", content: "[tools loaded: delegate (loader)]",
                             tool_change: { add: %w[delegate], by: "loader" })
    expect(session.messages.index(entry)).to eq(session.messages.index { |m| m[:role] == "user" } + 1)
  end

  it "loads from anywhere else at the next turn's start, once: idempotent across calls and turns" do
    engine, session = engine_on("ant:claude-x")
    loader = ctx(engine)
    3.times { server.enqueue("/v1/messages", sse: text_reply) }

    engine.run_turn(session, "first")
    expect(loader.load_tools(%w[delegate])).to eq(%w[delegate])
    expect(loader.load_tools(%w[delegate chi/delegate])).to eq([])
    engine.run_turn(session, "second")
    expect(loader.load_tools(%w[delegate])).to eq([])
    engine.run_turn(session, "third")

    expect(requests.map { |r| changes_in(r.json).size }).to eq([0, 1, 1])
    expect(session.messages.count { |m| m[:kind] == "tool_change" }).to eq(1)
    expect(requests.map { |r| r.header("anthropic-beta") }).to eq([nil, "inline-tools-2026-09-15", "inline-tools-2026-09-15"])
  end

  it "keeps a load staged when a Stop ends the turn before the model" do
    engine, session = engine_on("ant:claude-x")
    loader = ctx(engine)
    server.enqueue("/v1/messages", sse: text_reply)
    engine.run_turn(session, "first")
    expect(loader.load_tools(%w[delegate])).to eq(%w[delegate])
    # The next turn's Stop comes before its hooks (#prepare_turn false).
    calls = 0
    allow(engine).to receive(:prepare_turn).and_wrap_original do |original, *args|
      (calls += 1) == 1 ? false : original.call(*args)
    end

    engine.run_turn(session, "stopped")
    server.enqueue("/v1/messages", sse: text_reply)
    engine.run_turn(session, "again")

    expect(changes_in(requests.last.json).size).to eq(1)
  end

  it "sends and saves nothing on a host without tool changes, and says so in the log" do
    engine, session = engine_on("oai:gpt-x")
    logged = []
    allow(Samagotchi::Log).to receive(:info).and_call_original
    allow(Samagotchi::Log).to receive(:info).with(:plugins, "tool_loads_not_sent", anything) { |*_a, **f| logged << f }
    engine.register_hook(:before_turn) { |_e| ctx(engine).load_tools(%w[delegate]) }
    server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))

    engine.run_turn(session, "hi")

    body = server.requests.find { |r| r.path == "/v1/chat/completions" }.json
    expect(body["messages"].map { |m| m["role"] }).to eq(%w[system user])
    expect(session.messages.none? { |m| m[:kind] == "tool_change" }).to be(true)
    expect(logged).to eq([{ tools: "delegate", model: "oai:gpt-x" }])
  end

  it "takes no Array as an ArgumentError" do
    engine, = engine_on("ant:claude-x")
    expect { ctx(engine).load_tools("delegate") }.to raise_error(ArgumentError, /Array/)
  end

  describe "the entry, keyed on its kind" do
    let(:entry) { Samagotchi::ToolLoads.entry(%w[delegate], by: "loader") }

    it "is never the system head, counts as conversation, and a trailing note is found past it" do
      head = { role: "system", content: "new head" }
      expect(Samagotchi::ContextNote.with_system_head([entry, { role: "user", content: "x" }], head).first(2)).to eq([head, entry])
      expect(Samagotchi::SessionManager.no_conversation?([{ role: "system", content: "sys" }, entry])).to be(false)
      note = Samagotchi::TurnNote.cancelled(:user, seconds: 1)
      expect(Samagotchi::TurnNote.trailing_index([note, entry])).to eq(0)
    end

    it "reaches plugins' ctx.messages" do
      engine, session = engine_on("ant:claude-x")
      session.messages = [{ role: "system", content: "sys" }, { role: "user", content: "x" }, entry]
      expect(ctx(engine).messages.last).to include(kind: "tool_change")
    end
  end
end
