# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/toolkit"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require "samagotchi/tool_loads"
require "samagotchi/prompt"
require "samagotchi/model_profile"
require_relative "../support/fake_chat_adapter"
require_relative "../support/test_kernel"

# The tools a lean session reaches but doesn't declare go out deferred
# (defer_loading) only to an adapter that loads tools for the model
# (AnthropicMessages#loads_tools?; lean tools P2c), after the declared ones;
# a call of one is logged with whether the conversation had loaded it.
RSpec.describe "ChatLoop's deferred tools" do
  let(:kernel) do
    test_kernel(tools: Samagotchi::Tools::Builtins.registry).tap do |k|
      Samagotchi::Tools::ToolIndex.new.declare(k.tools)
      k.tools.toolkit = Samagotchi::Toolkit.new(name: "lean").resolve(Samagotchi::Toolkit.kits)
      allow(k).to receive(:dispatch_tool_call) do |call|
        { output: "[#{call[:name]}] done", activity: { action: "ran", tool: call[:name].to_s, status: "ok" } }
      end
    end
  end

  def adapter(*steps, loads: true)
    FakeChatAdapter.new(*steps).tap do |a|
      a.define_singleton_method(:loads_tools?) { |_model| loads } unless loads.nil?
    end
  end

  def run(chat, messages = [{ role: "user", content: "go" }])
    Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: chat).complete(messages: messages, model_name: "m",
                                                                          on_stream_event: ->(_e) {})
  end

  def deferred_names(request) = request[:tools].select { |t| t[:defer_loading] }.map { |t| t.dig(:function, :name) }

  it "appends the reachable tools deferred after the declared ones on an adapter that loads tools" do
    chat = adapter(FakeChatAdapter.text("ok"))

    run(chat)

    tools = chat.requests.first[:tools]
    expect(deferred_names(chat.requests.first)).to eq(%w[register_reminder cancel_reminder list_reminders list_sessions
                                                         send_note delegate delegate_result])
    expect(tools.index { |t| t[:defer_loading] }).to eq(tools.count { |t| !t[:defer_loading] })
    expect(tools.last).to include(type: "function", defer_loading: true)
  end

  it "sends none to an adapter that doesn't load tools, or doesn't say" do
    [false, nil].each do |loads|
      chat = adapter(FakeChatAdapter.text("ok"), loads: loads)
      run(chat)
      expect(deferred_names(chat.requests.first)).to eq([])
    end
  end

  it "sends none on Fireworks' dialect, nor for a model whose host refused them" do
    fireworks = Samagotchi::LLM::AnthropicMessages.new(base_url: "http://x.test", host_name: "fw", dialect: "fireworks", env: {})
    standard = Samagotchi::LLM::AnthropicMessages.new(base_url: "http://x.test", host_name: "a", env: {})
    standard.instance_variable_get(:@refusals).remember(:tool_loading, "old")

    expect(fireworks.loads_tools?("m")).to be(false)
    expect(standard.loads_tools?("m")).to be(true)
    expect(standard.loads_tools?("old")).to be(false)
  end

  it "filters source-group declarations for native and OpenAI-style requests without deferred tools" do
    registry = Samagotchi::Tools::Builtins.registry
    index = Samagotchi::Tools::ToolIndex.new
    source = index.source(label: "mcp", prefix: "mcp_", context: Object.new,
                          acts_as: ->(group, name) { "mcp_#{group}_#{name}" }, call: ->(*) { "ok" })
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "chrome")])
    index.add(source)
    index.declare(registry)
    registry.toolkit = Samagotchi::Toolkit::Resolved.new(name: "coding", all_core: true, groups: [])
    index.refresh!

    expect(Samagotchi::ToolDeclarations.native_schemas(registry).map { |schema| schema[:name] })
      .not_to include("find_tools", "call_tool")

    chat = adapter(FakeChatAdapter.text("ok"))
    filtered_kernel = test_kernel(tools: registry)
    Samagotchi::LLM::ChatLoop.new(kernel: filtered_kernel, adapter: chat)
      .complete(messages: [{ role: "user", content: "go" }], model_name: "m", on_stream_event: ->(_event) {})

    expect(chat.requests.first[:tools].map { |tool| tool.dig(:function, :name) })
      .not_to include("find_tools", "call_tool")
    expect(deferred_names(chat.requests.first)).to eq([])
  end

  it "logs a call of a tool the request deferred, with whether the conversation loaded it" do
    logged = []
    allow(Samagotchi::Log).to receive(:info).and_call_original
    allow(Samagotchi::Log).to receive(:info).with(:turn, "tool_direct_deferred", anything) { |*_a, **f| logged << f }
    chat = adapter(FakeChatAdapter.tools(%w[c1 list_sessions {}], %w[c2 delegate {}], %w[c3 read {}]),
                   FakeChatAdapter.text("ok"))
    history = [{ role: "tool_response", content: "[find_tools]\nx", loaded: %w[list_sessions] }]

    run(chat, history + [{ role: "user", content: "go" }])

    expect(logged).to eq([{ tool: "list_sessions", loaded: true }, { tool: "delegate", loaded: false }])
  end

  describe "a plugin's tool change entry" do
    let(:change) { Samagotchi::ToolLoads.entry(%w[delegate], by: "b") }
    let(:history) { [{ role: "system", content: "sys" }, { role: "user", content: "go" }, change] }

    it "goes only to an adapter that takes tool changes, never as an empty system message elsewhere" do
      taking = adapter(FakeChatAdapter.text("ok")).tap { |a| a.define_singleton_method(:tool_changes?) { |_m| true } }
      loop = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: taking)
      expect(loop.wire_messages(history).last).to eq(role: "system", content: change[:content], tool_change: change[:tool_change])

      [adapter(FakeChatAdapter.text("ok")), adapter(FakeChatAdapter.text("ok"), loads: nil)].each do |other|
        wire = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: other).wire_messages(history)
        expect(wire.map { |m| m[:role] }).to eq(%w[system user])
      end
    end

    it "is left out of a native prompt" do
      profile = Samagotchi::ModelProfile.normalize("qwen36")
      expect(Samagotchi::Prompt.format(history, profile: profile)).to eq(Samagotchi::Prompt.format(history.first(2), profile: profile))
    end
  end
end
