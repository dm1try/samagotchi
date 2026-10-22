# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/llm/openai_chat"
require "samagotchi/session"
require "samagotchi/toolkit"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require_relative "../support/fake_provider_server"
require_relative "../support/test_kernel"

# A lean session on a Messages host, end to end through the real
# AnthropicMessages, ToolRunner and KernelLoop dispatch (lean tools P2c,
# P1b): find_tools("sessions") loads list_sessions; the model calls it by
# name; the request after the load keeps the request before as its prefix.
RSpec.describe "A find_tools hit loads its tools (ChatLoop on a Messages host)" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }
  let(:index) { Samagotchi::Tools::ToolIndex.new }
  let(:kernel) do
    test_kernel(tools: Samagotchi::Tools::Builtins.registry).tap do |k|
      index.declare(k.tools)
      k.tools.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
      index.refresh!
      k.tools["list_sessions"].handler = ->(_call, _kctx) { "abc123 idle ~/w" }
      k.turn_settings = k.turn_settings.with(thinking: :high, reasoning_history: :all, loads_tools: true)
    end
  end
  let(:adapter) do
    Samagotchi::LLM::AnthropicMessages.new(base_url: server.root_url, host_name: "msg", env: {}, retries: false)
  end

  after { server.stop }

  def sse(*events) = events.map { |event| "event: #{event[:type]}\ndata: #{JSON.generate(event)}\n\n" }.join

  # A streamed reply that calls +name+ with +input+.
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

  def bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)

  def run(chat_adapter = adapter, messages = [{ role: "system", content: "sys" }, { role: "user", content: "list my sessions" }])
    Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: chat_adapter, sleeper: ->(_s) {})
                             .complete(messages: messages, model_name: "m", on_stream_event: ->(_e) {})
  end

  # A body's messages without cache marks (they move to the last block).
  def unmarked(messages) = JSON.parse(JSON.generate(messages).gsub(/,"cache_control":\{[^}]*\}/, ""))

  it "loads list_sessions from a find hit; the model calls it by name; the prefix holds" do
    server.enqueue("/v1/messages", sse: tool_use("toolu_f", "find_tools", { query: "sessions" }))
    server.enqueue("/v1/messages", sse: tool_use("toolu_l", "list_sessions", {}))
    server.enqueue("/v1/messages", sse: text_reply)
    allow(Samagotchi::Log).to receive(:info).and_call_original

    result = run

    expect(Samagotchi::Log).to have_received(:info).with(:turn, "tool_direct_deferred", tool: "list_sessions", loaded: true)

    first, second, third = bodies
    expect(second["tools"]).to eq(first["tools"])
    expect(third["tools"]).to eq(first["tools"])
    expect(first["tools"].find { |t| t["name"] == "list_sessions" }).to include("defer_loading" => true)
    load = second["messages"][2]["content"]
    expect(load.first).to include("type" => "tool_result", "tool_use_id" => "toolu_f")
    expect(load.first["content"].map { |ref| ref["tool_name"] }).to include("list_sessions")
    expect(load.last["text"]).to start_with("Loaded: list_sessions")
    expect(load.last["text"]).not_to include("Call one with call_tool")
    # The request after the direct call extends the one before.
    expect(unmarked(third["messages"].first(3))).to eq(unmarked(second["messages"]))
    saved = result.conversation.find { |e| e[:tool_call_id] == "toolu_f" }
    expect(saved[:loaded]).to include("list_sessions")
    expect(result.conversation.find { |e| e[:tool_call_id] == "toolu_l" }[:content]).to eq("[list_sessions]\nabc123 idle ~/w")
  end

  it "rebuilds the same bytes from a saved session (a respawn), the loads included" do
    server.enqueue("/v1/messages", sse: tool_use("toolu_f", "find_tools", { query: "sessions" }))
    server.enqueue("/v1/messages", sse: text_reply)
    server.enqueue("/v1/messages", sse: text_reply)
    conversation = run.conversation

    saved = JSON.parse(JSON.generate(conversation)).map { |m| Samagotchi::Session.send(:symbolize_message_keys, m) }
    # The saved history up to the load, as the second request had it.
    run(adapter, saved.first(4))

    expect(bodies[2]).to eq(bodies[1])
  end

  it "keeps a loaded name deferred as a stub once its source is gone, so the load renders the same" do
    source = index.source(label: "mcp", call: ->(*) { "ok" }, acts_as: ->(g, t) { "mcp_#{g}_#{t}" })
    tool = Samagotchi::Tools::ToolIndex::Tool.new(group: "fs", name: "sessions_log", acts_as: "mcp_fs_sessions_log",
                                                  description: "the sessions log")
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "fs", tools: [tool])])
    index.add(source)
    server.enqueue("/v1/messages", sse: tool_use("toolu_f", "find_tools", { query: "sessions log" }))
    server.enqueue("/v1/messages", sse: text_reply)
    server.enqueue("/v1/messages", sse: text_reply)
    conversation = run.conversation
    expect(conversation.find { |e| e[:tool_call_id] == "toolu_f" }[:loaded]).to include("mcp_fs_sessions_log")

    # A respawn with the server still starting: its group has no tools yet.
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "fs", state: :starting)])
    run(adapter, conversation)

    stub = bodies[2]["tools"].find { |t| t["name"] == "mcp_fs_sessions_log" }
    expect(stub).to include("defer_loading" => true, "description" => Samagotchi::Tools::DeferredTools::STUB_DESCRIPTION)
    expect(bodies[2]["messages"][2]).to eq(bodies[1]["messages"][2])
  end

  it "saves loaded: on an OpenAI session too, and sends none on its wire" do
    server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
    openai = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", env: {}, sleeper: ->(_s) {})
    history = [{ role: "system", content: "sys" }, { role: "user", content: "go" },
               { role: "model", content: "", tool_calls: [{ id: "c1", name: "find_tools", arguments: { "query" => "x" } }] },
               { role: "tool_response", content: "[find_tools]\nfound", tool_call_id: "c1", loaded: %w[list_sessions] },
               { role: "user", content: "again" }]

    result = run(openai, history)

    expect(result.conversation[3][:loaded]).to eq(%w[list_sessions])
    sent = server.requests.find { |r| r.path == "/v1/chat/completions" }.json
    expect(sent["messages"][3]).to eq("role" => "tool", "content" => "[find_tools]\nfound", "tool_call_id" => "c1")
    expect(sent["tools"].none? { |t| t.key?("defer_loading") }).to be(true)
  end
end
