# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/session"
require_relative "../support/fake_provider_server"
require_relative "../support/test_kernel"

# The chat loop on a Messages host (the real AnthropicMessages adapter against
# the fake server): a model entry keeps the response's blocks
# (anthropic_content) and they go back verbatim, the running run's thinking
# blocks always, earlier turns' as reasoning_history says (all by default on
# api: anthropic; drop is floored at turn).
RSpec.describe "ChatLoop on a Messages host" do
  around { |example| FakeProviderServer.without_webmock { example.run } }

  let(:server) { FakeProviderServer.start.tap { |s| s.default("/v1/models", json: { data: [] }) } }
  let(:kernel) do
    kernel = test_kernel
    allow(kernel).to receive(:strip_model_thought) { |text| text.to_s }
    known = Samagotchi::KernelLoop::TOOLS.map(&:name)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      name = call[:name].to_s
      output = known.include?(name) ? "[#{name}] done" : "Error: unknown tool '#{name}'."
      { output: output, activity: { action: "ran #{name}", tool: name, params: nil, status: "ok" } }
    end
    kernel
  end
  let(:adapter) do
    Samagotchi::LLM::AnthropicMessages.new(base_url: server.root_url, host_name: "msg", env: {}, retries: false)
  end
  let(:backend) { Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter, sleeper: ->(_s) {}) }
  let(:events) { [] }

  after { server.stop }

  def fixture(name) = FakeProviderServer.fixture(name, api: "anthropic")
  def answer(name) = server.enqueue("/v1/messages", sse: fixture(name))
  def bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)

  def level(value)
    kernel.turn_settings = kernel.turn_settings.with(reasoning_history: value)
  end

  def run(messages = [{ role: "user", content: "go" }])
    backend.complete(messages: messages, model_name: "m", on_stream_event: ->(event) { events << event })
  end

  # The blocks as a fixture's stream builds them (AnthropicAssembly).
  def blocks_of(name)
    assembly = Samagotchi::LLM::AnthropicAssembly.new
    fixture(name).lines.grep(/\Adata:/).each { |line| assembly.add(JSON.parse(line.delete_prefix("data:"))) }
    assembly.response.provider_content
  end

  it "sends a tool step's interleaved blocks back verbatim in the next step, the results in one user message" do
    level(:turn)
    answer("interleaved_stream.hand-written.sse")
    answer("text_stream.hand-written.sse")

    result = run

    expect(result.text).to eq("Hello! How can I help you today?")
    second = bodies[1]["messages"]
    expect(second[1]).to eq("role" => "assistant", "content" => blocks_of("interleaved_stream.hand-written.sse"))
    expect(second[2]["content"].map { |block| block["type"] }).to eq(%w[tool_result tool_result])
    expect(second[2]["content"].map { |block| block["tool_use_id"] })
      .to eq(%w[toolu_01ExampleListFiles00001 toolu_01ExampleReadReadme0001])
    saved = result.conversation.find { |entry| entry[:role] == "model" && entry[:tool_calls] }
    expect(saved[:anthropic_content]).to eq(blocks_of("interleaved_stream.hand-written.sse"))
  end

  it "replays the same bytes after a session file round trip (the blocks keep their string keys)" do
    level(:all)
    answer("thinking_tool_use_stream.hand-written.sse")
    answer("text_stream.hand-written.sse")
    answer("text_stream.hand-written.sse")
    first = run.conversation

    saved = JSON.parse(JSON.generate(first)).map { |message| Samagotchi::Session.send(:symbolize_message_keys, message) }
    run(saved + [{ role: "user", content: "again" }])

    live = bodies[1]["messages"][1]
    resumed = bodies[2]["messages"][1]
    expect(resumed).to eq(live)
    expect(resumed["content"].first).to include("type" => "thinking", "signature" => a_string_starting_with("EqQB"))
  end

  describe "earlier turns' thinking blocks" do
    let(:history) do
      [{ role: "user", content: "first" },
       { role: "model", content: "old answer", thinking: "old thought",
         anthropic_content: [{ "type" => "thinking", "thinking" => "old thought", "signature" => "sig" },
                             { "type" => "text", "text" => "old answer" }] },
       { role: "user", content: "second" }]
    end

    it "go back under all, the default for api: anthropic" do
      level(:all)
      answer("text_stream.hand-written.sse")

      run(history)

      expect(bodies[0]["messages"][1]["content"].map { |block| block["type"] }).to eq(%w[thinking text])
    end

    it "are removed under turn (only from the front: the text stays), and drop is floored at turn" do
      %i[turn drop].each do |value|
        level(value)
        answer("text_stream.hand-written.sse")
        run(history)
      end

      expect(bodies.map { |body| body["messages"][1]["content"] })
        .to eq([[{ "type" => "text", "text" => "old answer" }]] * 2)
      expect(backend.reasoning_history("m")).to eq(:turn)
    end

    it "the running run keeps its own under drop (a tool loop with thinking needs them)" do
      level(:drop)
      answer("thinking_tool_use_stream.hand-written.sse")
      answer("text_stream.hand-written.sse")

      run

      expect(bodies[1]["messages"][1]["content"].first["type"]).to eq("thinking")
    end
  end

  it "keeps the thinking of a run stopped after its tool step, under turn, on the next turn" do
    level(:turn)
    answer("text_stream.hand-written.sse")
    stopped = [{ role: "user", content: "go" },
               { role: "model", content: "", tool_calls: [{ id: "toolu_x", name: "execute", arguments: {} }],
                 anthropic_content: [{ "type" => "thinking", "thinking" => "t", "signature" => "s" },
                                     { "type" => "tool_use", "id" => "toolu_x", "name" => "execute", "input" => {} }] },
               { role: "tool_response", content: "ok", tool_call_id: "toolu_x" },
               { role: "user", content: "next" }]

    run(stopped)

    expect(bodies[0]["messages"][1]["content"].map { |block| block["type"] }).to eq(%w[thinking tool_use])
  end

  it "sends an entry with unpaired calls as flattened text, without its blocks" do
    level(:all)
    answer("text_stream.hand-written.sse")
    broken = [{ role: "user", content: "go" },
              { role: "model", content: "", tool_calls: [{ id: "toolu_x", name: "execute", arguments: { "command" => "ls" } }],
                anthropic_content: [{ "type" => "thinking", "thinking" => "t", "signature" => "s" },
                                    { "type" => "tool_use", "id" => "toolu_x", "name" => "execute", "input" => {} }] },
              { role: "user", content: "next" }]

    run(broken)

    expect(bodies[0]["messages"][1]).to eq("role" => "assistant",
                                           "content" => [{ "type" => "text", "text" => '[tool call] execute {"command":"ls"}' }])
  end

  it "keeps no blocks on an interrupted entry" do
    level(:all)
    answer("text_stream.hand-written.sse")
    cut = [{ role: "user", content: "go" },
           { role: "model", content: "half\n[interrupted]", interrupted: true,
             anthropic_content: [{ "type" => "text", "text" => "half" }] },
           { role: "user", content: "next" }]

    run(cut)

    expect(bodies[0]["messages"][1]["content"]).to eq([{ "type" => "text", "text" => "half\n[interrupted]" }])
  end

  it "answers a malformed streamed tool name with the unknown-tool error, then goes on" do
    answer("splash_tool_stream_bad_name.sse")
    answer("text_stream.hand-written.sse")

    result = run

    results = result.conversation.select { |entry| entry[:role] == "tool_response" }
    expect(results.map { |entry| entry[:content] }).to all(include("unknown tool"))
    expect(result.text).to eq("Hello! How can I help you today?")
    # Sent back with a name Messages takes (it validates ^[a-zA-Z0-9_-]{1,128}$).
    replayed = bodies[1]["messages"][1]["content"].select { |block| block["type"] == "tool_use" }
    expect(replayed.map { |block| block["name"] }).to all(match(/\A[a-zA-Z0-9_-]{1,128}\z/))
  end

  it "ends the turn normally after a budget-capped thinking (no retry, no cap count)" do
    answer("thinking_budget_capped_stream.hand-written.sse")

    result = run

    expect(bodies.size).to eq(1)
    expect(result.text).not_to be_empty
    completed = events.find { |event| event[:type] == :generation_completed }
    expect(completed[:finish_reason]).to eq("stop")
  end
end
