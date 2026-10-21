# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/openai_chat"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/prompt"
require "samagotchi/model_profile"
require "samagotchi/toolkit"
require "samagotchi/tool_declarations"
require "samagotchi/tools/builtins"
require "samagotchi/tools/tool_index"
require_relative "../support/fake_provider_server"
require_relative "../support/test_kernel"

# Byte goldens of a request on each wire, for full and lean, each with and
# without a tool source (a fake MCP server's group): the OpenAI chat body,
# the Messages body with the headers chi sets, and the native prompt (the
# qwen36 tool declarations, then the conversation as Prompt.format renders
# it). The conversation holds a find_tools hit and its result, so how a
# found tool is answered and declared shows here (lean tools P2c). The
# OpenAI and native goldens, and the Messages one on full without a source,
# never change with it.
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/llm/request_goldens_spec.rb
RSpec.describe "Request goldens per toolkit and wire" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }

  after { server.stop }

  def fixture_dir = File.expand_path("../fixtures/request_goldens", __dir__)

  def expect_golden(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  # A fake MCP server's group, as the mcp bundle publishes one.
  def mcp_source(index)
    source = index.source(label: "mcp", prefix: "mcp_", call: ->(_tool, _args, _ctx) { "ok" },
                          acts_as: ->(group, tool) { "mcp_#{group}_#{tool}" })
    tools = [["read_file", "Read a file's text."], ["list_sessions_log", "List the sessions log."]].map do |name, text|
      Samagotchi::Tools::ToolIndex::Tool.new(group: "fs", name: name, acts_as: "mcp_fs_#{name}", description: text,
                                             schema: { "type" => "object",
                                                       "properties" => { "path" => { "type" => "string" } } })
    end
    source.publish([Samagotchi::Tools::ToolIndex::Group.new(name: "fs", summary: "files", tools: tools)])
    index.add(source)
  end

  def kernel_for(toolkit, mcp)
    kernel = test_kernel(tools: Samagotchi::Tools::Builtins.registry)
    index = Samagotchi::Tools::ToolIndex.new
    mcp_source(index) if mcp
    index.declare(kernel.tools)
    kernel.tools.toolkit = Samagotchi::Toolkit.new(name: toolkit).resolve(Samagotchi::Toolkit.kits)
    index.refresh!
    kernel.turn_settings = kernel.turn_settings.with(thinking: :high, reasoning_history: :all)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      { output: "[#{call[:name]}] done", activity: { action: "ran #{call[:name]}", tool: call[:name].to_s, status: "ok" } }
    end
    [kernel, index]
  end

  # A find_tools hit and its answer (with the tools it loads, as
  # ToolResponse.single saves them), then a new prompt.
  def conversation(index)
    found = index.find("sessions")
    result = { role: "tool_response", content: "[find_tools]\n#{found}", tool_call_id: "toolu_find1" }
    result[:loaded] = found.loaded unless found.loaded.empty?
    [{ role: "system", content: "You are chi. Use tools when needed." },
     { role: "user", content: "List my chi sessions." },
     { role: "model", content: "", tool_calls: [{ id: "toolu_find1", name: "find_tools", arguments: { "query" => "sessions" } }] },
     result,
     { role: "model", content: "Found it." },
     { role: "user", content: "Now list them." }]
  end

  def recorded(path, header_names)
    request = server.requests.find { |r| r.path == path }
    JSON.pretty_generate("headers" => request.headers.slice(*header_names), "body" => request.json) + "\n"
  end

  [["full", false], ["full", true], ["lean", false], ["lean", true]].each do |toolkit, mcp|
    name = "#{toolkit}#{"_mcp" if mcp}"

    it "keeps the OpenAI chat body on #{name}" do
      kernel, index = kernel_for(toolkit, mcp)
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
      adapter = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", env: {}, sleeper: ->(_s) {})
      loop = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
      loop.session_id = "sess-golden"

      loop.complete(messages: conversation(index), model_name: "box-model", on_stream_event: ->(_event) {})

      expect_golden("#{name}_openai.json", recorded("/v1/chat/completions", %w[content-type session-id]))
    end

    it "keeps the Messages body and headers on #{name}" do
      kernel, index = kernel_for(toolkit, mcp)
      server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("text_stream.hand-written.sse", api: "anthropic"))
      adapter = Samagotchi::LLM::AnthropicMessages.new(base_url: server.root_url, host_name: "msg", env: {}, retries: false)
      loop = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter, sleeper: ->(_s) {})
      loop.session_id = "sess-golden"

      loop.complete(messages: conversation(index), model_name: "claude-golden", on_stream_event: ->(_event) {})

      expect_golden("#{name}_anthropic.json",
                    recorded("/v1/messages", %w[content-type anthropic-version anthropic-beta session-id]))
    end

    it "keeps the native prompt on #{name}" do
      kernel, index = kernel_for(toolkit, mcp)
      profile = Samagotchi::ModelProfile.normalize("qwen36")
      declarations = Samagotchi::ToolDeclarations.qwen_declarations(
        Samagotchi::ToolDeclarations.native_schemas(kernel.tools, layers: [])
      )
      messages = conversation(index)
      messages[0] = messages[0].merge(content: "#{messages[0][:content]}\n\n#{declarations}")

      expect_golden("#{name}_native.txt", Samagotchi::Prompt.format(messages, profile: profile))
    end
  end
end
