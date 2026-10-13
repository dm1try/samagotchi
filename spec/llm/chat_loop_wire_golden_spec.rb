# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/llm/backend"
require "samagotchi/llm/chat_loop"
require_relative "../support/fake_provider_server"
require_relative "../support/test_kernel"

# Byte-for-byte goldens of what ChatLoop sends an api: openai host for a
# tool turn: the real OpenAIChat against the fake server, a thinking level,
# sampling, a session id and an earlier turn with reasoning and a tool call,
# at each reasoning_history level (drop sends no reasoning_content; turn the
# running turn's; all every model entry's). They pin the OpenAI wire while
# the adapter seams move (P2b P0). One tool (read) keeps its full definition
# (the function wrapping); the others are reduced to their names (their
# texts change with the tools, not with the wire).
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/llm/chat_loop_wire_golden_spec.rb
RSpec.describe "ChatLoop OpenAI wire goldens" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start }
  let(:kernel) do
    kernel = test_kernel
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      { output: "[#{call[:name]}] done", activity: { action: "ran #{call[:name]}", tool: call[:name].to_s, params: nil, status: "ok" } }
    end
    kernel
  end

  after { server.stop }

  def fixture_dir = File.expand_path("../fixtures/prompt_goldens", __dir__)

  def expect_golden(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  def conversation
    [{ role: "system", content: "You are chi. Use tools when needed." },
     { role: "user", content: "What is in notes.txt?" },
     { role: "model", content: "", thinking: "read it first",
       tool_calls: [{ id: "c0", name: "read", arguments: { "path" => "notes.txt" } }] },
     { role: "tool_response", content: "[read]\n1: buy milk", tool_call_id: "c0" },
     { role: "model", content: "It says to buy milk.", thinking: "summarise" },
     { role: "user", content: "List the files, then say done." }]
  end

  # Each chat request's body with the tools as names, and the headers chi sets.
  def chat_requests = server.requests.select { |request| request.path == "/v1/chat/completions" }

  def recorded
    chat_requests.map do |request|
      body = request.json
      body["tools"] = Array(body["tools"]).map do |tool|
        tool.dig("function", "name") == "read" ? tool : tool.dig("function", "name")
      end
      headers = request.headers.slice("content-type", "session-id")
      JSON.pretty_generate("path" => request.path, "headers" => headers, "body" => body)
    end.join("\n")
  end

  # [thinking level, reasoning_history, golden name]
  [[:off, :drop, "off"], [:low, :drop, "low"], [:low, :turn, "low_turn"], [:low, :all, "low_all"]].each do |level, history, name|
    it "keeps the request bodies of a tool turn at thinking #{level}, reasoning history #{history}" do
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("reasoning_tool_stream.sse"))
      server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
      kernel.turn_settings = kernel.turn_settings.with(thinking: level, sampling: { temperature: 0.6 },
                                                       reasoning_history: history)
      adapter = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", env: {}, sleeper: ->(_s) {})
      loop = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
      loop.session_id = "sess-golden"

      loop.complete(messages: conversation, model_name: "box-model", on_stream_event: ->(_event) {})

      expect(chat_requests.size).to eq(2)
      expect_golden("chat_loop_tool_turn_#{name}.json", recorded)
    end
  end
end
