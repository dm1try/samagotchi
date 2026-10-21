# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/anthropic_messages"
require "samagotchi/llm/anthropic_wire"
require "samagotchi/llm/prompt_cache"
require_relative "../support/fake_provider_server"

# A find_tools hit loads its matches on a Messages host (lean tools P2c,
# P1b): the result goes as tool_reference blocks, its text as a sibling
# block; and the 400s a host may answer deferred tools with are fixed per
# model (:tool_loading, :tool_schema).
RSpec.describe "Tool loading on a Messages host" do
  let(:cache) { { type: "ephemeral" } }

  def deferred_tool(name, schema: { type: "object", properties: {} })
    { type: "function", function: { name: name, description: "#{name} it", parameters: schema }, defer_loading: true }
  end

  def declared_tool(name) = deferred_tool(name).except(:defer_loading)

  # A find result that loaded +loaded+, then a prompt (or nothing after it).
  def wire(loaded, after: true)
    [{ role: "system", content: "sys" }, { role: "user", content: "go" },
     { role: "assistant", content: nil,
       tool_calls: [{ id: "toolu_f", type: "function", function: { name: "find_tools", arguments: "{}" } }] },
     { role: "tool", content: "[find_tools]\nfound", tool_call_id: "toolu_f", loaded: loaded },
     *([{ role: "user", content: "again" }] if after)]
  end

  describe Samagotchi::LLM::AnthropicWire do
    def result_message(translated) = translated.messages[2]

    it "loads only the names deferred in this request, the text after the references" do
      translated = described_class.translate(wire(%w[list_sessions read], after: false), deferred: %w[list_sessions delegate])

      expect(result_message(translated)[:content]).to eq([
        { type: "tool_result", tool_use_id: "toolu_f", content: [{ type: "tool_reference", tool_name: "list_sessions" }] },
        { type: "text", text: "[find_tools]\nfound\n\nLoaded: list_sessions. Call them directly by these names " \
                              "(call_tool works too)." }
      ])
    end

    it "sends today's text when no loaded name is deferred here (declared since, or no tool loading)" do
      [[], %w[delegate]].each do |deferred|
        translated = described_class.translate(wire(%w[list_sessions], after: false), deferred: deferred)
        expect(result_message(translated)[:content])
          .to eq([{ type: "tool_result", tool_use_id: "toolu_f", content: "[find_tools]\nfound" }])
      end
    end

    it "never marks the sibling text: the mark goes on the last reference" do
      translated = described_class.translate(wire(%w[list_sessions send_note], after: false), cache: cache,
                                                                                               deferred: %w[list_sessions send_note])

      result, text = result_message(translated)[:content]
      expect(result[:content].map { |ref| ref.key?(:cache_control) }).to eq([false, true])
      expect(result).not_to have_key(:cache_control)
      expect(text).not_to have_key(:cache_control)
    end

    describe "a plugin's tool change (ctx.load_tools)" do
      let(:change) { { role: "system", content: "[tools loaded: delegate, gone (b)]", tool_change: { add: %w[delegate gone], by: "b" } } }

      it "goes as a system message of its own, after the user turn it sits in: never merged, deferred names only" do
        wire = [{ role: "system", content: "sys" }, { role: "user", content: "go" }, change,
                { role: "system", content: "[CONTEXT NOTE] x" }, { role: "user", content: "more" },
                { role: "assistant", content: "ok" }]

        messages = described_class.translate(wire, cache: cache, deferred: %w[delegate]).messages

        expect(messages.map { |m| m[:role] }).to eq(%w[user system assistant])
        expect(messages[0][:content].map { |b| b[:text] }).to eq(["go", "[CONTEXT NOTE] x", "more"])
        expect(messages[1]).to eq(role: "system", content: [{ type: "tool_addition",
                                                              tool: { type: "tool_reference", name: "delegate" } }])
        expect(messages[0][:content].last).to have_key(:cache_control)
      end

      it "follows a turn's tool results, and is last when nothing comes after it" do
        wire = [{ role: "system", content: "sys" }, { role: "user", content: "go" },
                { role: "assistant", content: nil, tool_calls: [{ id: "c1", type: "function", function: { name: "read", arguments: "{}" } }] },
                { role: "tool", content: "[read] x", tool_call_id: "c1" }, change]

        messages = described_class.translate(wire, deferred: %w[delegate]).messages

        expect(messages.map { |m| m[:role] }).to eq(%w[user assistant user system])
      end

      it "is dropped when none of its names is deferred here" do
        messages = described_class.translate([{ role: "user", content: "go" }, change], deferred: []).messages
        expect(messages.map { |m| m[:role] }).to eq(%w[user])
      end
    end

    it "puts no cache_control on a deferred tool" do
      expect(described_class.tools([deferred_tool("a")]).first).to eq(name: "a", description: "a it",
                                                                      input_schema: { type: "object", properties: {} },
                                                                      defer_loading: true)
    end
  end

  describe Samagotchi::LLM::AnthropicMessages do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    let(:server) { FakeProviderServer.start }
    let(:adapter) do
      described_class.new(base_url: server.root_url, host_name: "msg", env: {}, stream: false, sleeper: ->(_s) {},
                          retry_policy: Samagotchi::LLM::HTTP::RetryPolicy.new(max: 0, base_delay: 0.1, max_delay: 1.0))
    end
    let(:tools) { [declared_tool("find_tools"), deferred_tool("list_sessions"), deferred_tool("mcp_a"), deferred_tool("mcp_b")] }

    after { server.stop }

    def answer = server.enqueue("/v1/messages", json: FakeProviderServer.fixture("splash_text_sync.json", api: "anthropic"))

    def refuse(message)
      server.enqueue("/v1/messages", status: 400, json: { type: "error", error: { type: "invalid_request_error", message: message } })
    end

    def bodies = server.requests.select { |r| r.path == "/v1/messages" }.map(&:json)

    def chat(model: "m", messages: wire(%w[list_sessions mcp_b])) = adapter.chat(messages: messages, model: model, tools: tools)

    def deferred_in(body) = body["tools"].select { |t| t["defer_loading"] }.map { |t| t["name"] }

    def refs_in(body) = JSON.generate(body["messages"]).scan(/"tool_name":"(\w+)"/).flatten

    it "takes a deferred-tools refusal per model: asked again with none, loads as text, the next model unharmed" do
      refuse("tools.1: Extra inputs are not permitted (defer_loading)")
      answer
      answer
      answer

      chat
      chat
      chat(model: "other")

      expect(bodies.map { |b| deferred_in(b) }).to eq([%w[list_sessions mcp_a mcp_b], [], [], %w[list_sessions mcp_a mcp_b]])
      expect(refs_in(bodies[1])).to eq([])
      expect(adapter.loads_tools?("m")).to be(false)
      expect(adapter.loads_tools?("other")).to be(true)
    end

    it "drops each deferred tool whose schema the host refuses, per model; a load then references the rest" do
      refuse("tools.2.custom.input_schema: JSON schema is invalid")
      # The second request has mcp_a out: mcp_b is tools.2 there.
      refuse("tools.2.custom.input_schema: JSON schema is invalid")
      answer
      answer

      chat
      chat(model: "other")

      expect(bodies.map { |b| deferred_in(b) })
        .to eq([%w[list_sessions mcp_a mcp_b], %w[list_sessions mcp_b], %w[list_sessions], %w[list_sessions mcp_a mcp_b]])
      expect([refs_in(bodies[0]), refs_in(bodies[2]), refs_in(bodies[3])])
        .to eq([%w[list_sessions mcp_b], %w[list_sessions], %w[list_sessions mcp_b]])
    end

    it "recovers a signature 400 that the fallback's retry causes, as any other (the binding recovery)" do
      refuse("tools.1: defer_loading is not supported")
      server.enqueue("/v1/messages", status: 400,
                                     json: FakeProviderServer.fixture("claude_error_400_signature_system_changed.json", api: "anthropic"))
      server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("claude_drop_block_input_transformations.sse", api: "anthropic"))
      thinking = { "type" => "thinking", "thinking" => "t", "signature" => "sig1" }
      messages = wire(%w[list_sessions]).tap do |w|
        w[2] = w[2].merge(anthropic_content: [thinking, { "type" => "tool_use", "id" => "toolu_f", "name" => "find_tools",
                                                          "input" => {} }])
      end
      adapter.instance_variable_set(:@stream, true)

      response = adapter.chat(messages: messages, model: "claude-haiku-5-5", tools: tools,
                              options: { max_tokens: 1000, **adapter.thinking_fields(:high) })

      expect(bodies.size).to eq(3)
      expect(deferred_in(bodies[1])).to eq([])
      expect(response.thinking_drop).not_to be_nil
    end

    describe "a tool change on the wire" do
      let(:change) { { role: "system", content: "[tools loaded: list_sessions (b)]", tool_change: { add: %w[list_sessions], by: "b" } } }

      def betas = server.requests.select { |r| r.path == "/v1/messages" }.map { |r| r.header("anthropic-beta") }

      it "carries the inline-tools beta only with one" do
        answer
        answer
        chat(messages: wire([]))
        chat(messages: wire([]) + [change])

        expect(betas).to eq([nil, described_class::INLINE_TOOLS_BETA])
      end

      it "asks again without the change and the beta when the host refuses it, per model" do
        refuse("messages.4.role: Input should be 'user' or 'assistant' (system role not supported)")
        answer
        answer

        chat(messages: wire([]) + [change])
        chat(messages: wire([]) + [change])

        expect(bodies.map { |b| b["messages"].count { |m| m["role"] == "system" } }).to eq([1, 0, 0])
        expect(betas).to eq([described_class::INLINE_TOOLS_BETA, nil, nil])
        expect(adapter.tool_changes?("m")).to be(false)
        expect(adapter.loads_tools?("m")).to be(true)
      end

      it "joins the binding beta on a drop_block step, and the strip leaves the system message alone" do
        server.enqueue("/v1/messages", status: 400,
                                       json: FakeProviderServer.fixture("claude_error_400_signature_system_changed.json", api: "anthropic"))
        server.enqueue("/v1/messages", sse: FakeProviderServer.fixture("claude_drop_block_input_transformations.sse", api: "anthropic"))
        thinking = { "type" => "thinking", "thinking" => "t", "signature" => "sig1" }
        messages = wire([], after: false).tap do |w|
          w[2] = w[2].merge(anthropic_content: [thinking, { "type" => "tool_use", "id" => "toolu_f", "name" => "find_tools",
                                                            "input" => {} }])
        end
        adapter.instance_variable_set(:@stream, true)

        adapter.chat(messages: messages + [change], model: "claude-haiku-5-5", tools: tools,
                     options: { max_tokens: 1000, **adapter.thinking_fields(:high) })

        expect(betas.last).to eq("#{Samagotchi::LLM::AnthropicBindingRecovery::BINDING_BETA},#{described_class::INLINE_TOOLS_BETA}")
        expect(bodies.last["messages"].last).to eq("role" => "system", "content" => [
          { "type" => "tool_addition", "tool" => { "type" => "tool_reference", "name" => "list_sessions" } }
        ])
      end
    end

    it "fails a request whose 400 names a declared tool's schema, as before" do
      refuse("tools.0.custom.input_schema: JSON schema is invalid")

      expect { chat }.to raise_error(Samagotchi::LLM::BadRequest)
      expect(bodies.size).to eq(1)
    end

    it "fixes at most #{described_class::MAX_SCHEMA_FIXES} schemas in one request" do
      many = [declared_tool("find_tools"), *(1..7).map { |n| deferred_tool("mcp_#{n}") }]
      # tools.1 is the first deferred tool left each time.
      6.times { refuse("tools.1.custom.input_schema: bad") }
      answer

      expect { adapter.chat(messages: wire([]), model: "m", tools: many) }.to raise_error(Samagotchi::LLM::BadRequest)
      expect(bodies.size).to eq(described_class::MAX_SCHEMA_FIXES + 1)
    end
  end
end
