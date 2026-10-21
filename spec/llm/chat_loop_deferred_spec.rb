# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/toolkit"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
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
end
