# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::RubyLLMBackend do
  # A fake KernelLoop stand-in for the shared dispatch/stripping path, plus a
  # fake gem provider + connection that stub the raw HTTP boundary
  # (gem_provider.connection.post). We never hit the network or need an OpenAI
  # key. The backend is constructed with `kernel:` so @kernel is never nil.
  let(:fake_kernel) do
    kernel = double("kernel")
    # Strip Gemma-4 style <|think|>…<|think|> blocks (the format the tests use);
    # profile-specific stripping is unit-tested on KernelLoop itself.
    allow(kernel).to receive(:strip_model_thought) do |text|
      text.to_s.gsub(/<\|think\|>.*?<\|think\|>/m, "").strip
    end
    known_tools = Samagotchi::KernelLoop::TOOLS.map(&:name)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      name = call[:name].to_s
      output =
        if known_tools.include?(name)
          "[#{name}] done: #{call[:content]}"
        else
          "Error: unknown tool '#{name}'. Available: #{known_tools.join(', ')}"
        end
      {
        output: output,
        activity: { action: "ran #{name}", tool: name, params: nil, status: "ok" }
      }
    end
    kernel
  end

  let(:backend) { described_class.new(model_name: "custom-local-model", kernel: fake_kernel) }

  # The raw HTTP seam the tool-loop actually calls: gem_provider.connection.post.
  # `responses` is a list returned in call order; `request_bodies`/`request_urls`
  # capture every request so examples can assert on the wire shape.
  let(:request_bodies) { [] }
  let(:request_urls) { [] }

  def install_provider!(responses)
    responses = [responses] unless responses.is_a?(Array)
    fallback = responses.last # returned when the sequence is exhausted (repeat the last)
    fake_provider = instance_double(RubyLLM::Providers::OpenAI)
    connection = instance_double("Connection")
    allow(fake_provider).to receive(:api_base).and_return("http://localhost:8081/v1")
    allow(connection).to receive(:post) do |url, body|
      request_urls << url
      request_bodies << body
      responses.shift || fallback
    end
    allow(fake_provider).to receive(:connection).and_return(connection)
    allow_any_instance_of(described_class).to receive(:gem_provider).and_return(fake_provider)
  end

  # OpenAI-wire response bodies.
  def body_with_text(text)
    { "choices" => [{ "message" => { "content" => text } }] }
  end

  def wire_tool_call(id:, name:, arguments:)
    { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => arguments } }
  end

  def body_with_tool(id:, name:, arguments:)
    { "choices" => [{ "message" => {
      "content" => "",
      "tool_calls" => [wire_tool_call(id: id, name: name, arguments: arguments)]
    }}]}
  end

  # Install a blocking gem provider whose single `post` signals via `entered`
  # and sleeps (simulating a Faraday socket read) so a peer cancel lands.
  def install_blocking_provider!(entered, response_body)
    allow_any_instance_of(described_class).to receive(:gem_provider) do
      fp = instance_double(RubyLLM::Providers::OpenAI)
      conn = instance_double("Connection")
      allow(fp).to receive(:api_base).and_return("http://localhost:8081/v1")
      allow(conn).to receive(:post) do
        entered << :inflight
        sleep(30)
        double(body: response_body)
      end
      allow(fp).to receive(:connection).and_return(conn)
      fp
    end
  end

  describe "registration" do
    it "is a ModelBackend subclass" do
      expect(backend).to be_a(Samagotchi::LLM::ModelBackend)
    end
  end

  describe "#complete — inbound message mapping (wire shape)" do
    it "maps engine roles to gem symbols (:model -> :assistant; system/user pass through)" do
      install_provider!([body_with_text("ok")])

      backend.complete(messages: [
        { role: "system", content: "sys" },
        { role: "user", content: "hi" },
        { role: "model", content: "last" }
      ])

      # :model -> :assistant (so the gem never sees :model); system passes through
      # as raw string; user content is wrapped in OpenAI array format.
      expect(request_bodies.last[:messages].map { |m| m[:role] }).to eq(%w[system user assistant])
      expect(request_bodies.last[:messages].map { |m| m[:content] }).to eq(
        ["sys", [{ type: "text", text: "hi" }], "last"]
      )
    end
  end

  describe "#complete — single-pass text completion" do
    before { install_provider!([body_with_text("hello back")]) }

    it "returns a ModelResult mirroring the read surface" do
      result = backend.complete(messages: [{ role: "user", content: "hi" }])

      expect(result).to be_a(Samagotchi::LLM::ModelResult)
      expect(result.text).to eq("hello back")
      expect(result.output).to eq("hello back")
      expect(result.tool_calls).to be_nil
      expect(result.provider).to eq(:ruby_llm)
      expect(result.canceled?).to be(false)
    end

    it "serializes the conversation back to string role keys (assistant -> \"model\")" do
      result = backend.complete(messages: [{ role: "user", content: "hi" }])

      expect(result.conversation).to eq([
        { role: "user", content: "hi" },
        { role: "model", content: "hello back" }
      ])
    end
  end

  describe "#complete — streaming events" do
    it "emits :generation_chunk + one :generation_completed per generation (terminal spinner contract)" do
      events = []
      install_provider!([body_with_text("chunk1chunk2")])

      backend.complete(
        messages: [{ role: "user", content: "hi" }],
        on_stream_event: ->(event) { events << event }
      )

      chunks = events.select { |e| e[:type] == :generation_chunk }
      expect(chunks.map { |e| e[:content] }).to eq(["chunk1chunk2"])
      completed = events.select { |e| e[:type] == :generation_completed }
      expect(completed.length).to eq(1)
      expect(completed.first[:content_length]).to eq(12)
    end
  end

  describe "#complete — cancellation off the main thread" do
    it "raises RequestCancelled into the request thread, returning a clean canceled result with no dangling turn" do
      entered = Queue.new
      cc = Samagotchi::Client::CancellationController.new
      install_blocking_provider!(entered, body_with_text("nope"))

      result_holder = {}
      worker = Thread.new do
        result_holder[:result] = backend.complete(
          messages: [{ role: "user", content: "go" }],
          cancel_controller: cc
        )
      rescue StandardError => e
        result_holder[:error] = e
      end

      # Wait until the fake is actually blocked inside post (so cancel lands).
      expect(entered.pop).to eq(:inflight)
      cc.cancel!("loop-cancel")
      worker.join(5)

      expect(result_holder[:error]).to be_nil
      expect(result_holder[:result].canceled?).to be(true)
      expect(result_holder[:result].cancellation_reason).to eq("loop-cancel")
      expect(result_holder[:result].text).to eq("")
      # No partial assistant/tool turn leaked into the conversation.
      expect(result_holder[:result].conversation).to eq([{ role: "user", content: "go" }])
    end
  end

  describe "#complete — cancel on the main thread" do
    it "degrades gracefully: completion runs inline on the main thread, no raise into it, valid result" do
      cc = Samagotchi::Client::CancellationController.new
      # Fire the cancel inside the (inline, main-thread) post. On the main thread
      # there is no request thread/listener, so cancel! only records the reason.
      allow_any_instance_of(described_class).to receive(:gem_provider) do
        fp = instance_double(RubyLLM::Providers::OpenAI)
        conn = instance_double("Connection")
        allow(fp).to receive(:api_base).and_return("http://localhost:8081/v1")
        allow(conn).to receive(:post) do
          cc.cancel!("main-thread-cancel")
          body_with_text("chunkAchunkB")
        end
        allow(fp).to receive(:connection).and_return(conn)
        fp
      end

      result = backend.complete(
        messages: [{ role: "user", content: "hi" }],
        cancel_controller: cc
      )

      expect(result.canceled?).to be(false)
      expect(result.text).to eq("chunkAchunkB")
      expect(result.output).to eq("chunkAchunkB")
    end
  end

  describe "#complete — resume across turns" do
    it "after a cancel the returned conversation lacks the assistant turn, so the next reseed is clean" do
      cc = Samagotchi::Client::CancellationController.new
      entered = Queue.new
      post_calls = []

      # Single provider stub for the whole example: turn 1 blocks (cancel),
      # turn 2 returns the follow-up.
      allow_any_instance_of(described_class).to receive(:gem_provider) do
        fp = instance_double(RubyLLM::Providers::OpenAI)
        conn = instance_double("Connection")
        allow(fp).to receive(:api_base).and_return("http://localhost:8081/v1")
        allow(conn).to receive(:post) do
          post_calls << :post
          if post_calls.length == 1
            entered << :inflight
            sleep(30)
            double(body: body_with_text("nope"))
          else
            body_with_text("part two")
          end
        end
        allow(fp).to receive(:connection).and_return(conn)
        fp
      end

      # First turn cancels mid-flight (assistant never added).
      result_holder = {}
      worker = Thread.new do
        result_holder[:result] = backend.complete(
          messages: [{ role: "user", content: "Ask part one" }],
          cancel_controller: cc
        )
      rescue StandardError => e
        result_holder[:error] = e
      end
      expect(entered.pop).to eq(:inflight)
      cc.cancel!("cancel-1")
      worker.join(5)

      expect(result_holder[:result].canceled?).to be(true)
      expect(result_holder[:result].conversation).to eq([{ role: "user", content: "Ask part one" }])

      # Second turn re-seeds from the (assistant-less) conversation — no dangling turn.
      # The engine builds a fresh cancel controller per turn, so cancel-1's state
      # does not leak into turn 2.
      result2 = backend.complete(
        messages: result_holder[:result].conversation,
        cancel_controller: Samagotchi::Client::CancellationController.new
      )

      expect(result2.canceled?).to be(false)
      expect(result2.text).to eq("part two")
      expect(result2.conversation).to eq([
        { role: "user", content: "Ask part one" },
        { role: "model", content: "part two" }
      ])
    end
  end

  describe "statelessness" do
    it "issues a fresh request from messages: each call (no gem Chat retained across calls)" do
      install_provider!([body_with_text("one"), body_with_text("two")])

      backend.complete(messages: [{ role: "user", content: "hi" }])
      backend.complete(messages: [{ role: "user", content: "hi again" }])

      # Two POSTs, each built from its own messages — no shared/cached gem Chat.
      expect(request_bodies.length).to eq(2)
      expect(request_bodies.first[:messages].map { |m| m[:content] }).to eq([[{ type: "text", text: "hi" }]])
      expect(request_bodies.last[:messages].map { |m| m[:content] }).to eq([[{ type: "text", text: "hi again" }]])
    end
  end

  describe "#complete — outbound message serialization" do
    it "strips the in-flight tool_call_id from the returned conversation (plain {role:, content:} shape)" do
      install_provider!([body_with_text("ok")])

      result = backend.complete(messages: [
        { role: "user", content: "hi" },
        { role: "tool_response", content: "out", tool_call_id: "c1" }
      ])

      expect(result.conversation).to eq([
        { role: "user", content: "hi" },
        { role: "tool_response", content: "out" },
        { role: "model", content: "ok" }
      ])
    end
  end

  # ── Phase 3: agentic tool-round loop ──────────────────────────────────────────
  # Responses are a SEQUENCE: each `post` returns the next entry; the final entry
  # is a plain text answer that breaks the loop. (A single tool-only response would
  # loop to max_iterations, since a stubbed post returns its last value every call.)
  describe "#complete — native tool-round loop" do
    it "AC#1: a plain text answer yields a ModelResult with tool_calls nil" do
      install_provider!([body_with_text("here is the answer")])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      expect(result.tool_calls).to be_nil
      expect(result.text).to eq("here is the answer")
      # Natural completion (a clean answer, not the cap) is not exhausted.
      expect(result.exhausted?).to be(false)
    end

    it "AC#2: a single native Execute executes via dispatch, feeds the result, returns the follow-up text" do
      install_provider!([
        body_with_tool(id: "c1", name: "execute", arguments: '{"command":"echo hi"}'),
        body_with_text("the follow-up")
      ])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      expect(result.tool_calls).to be_nil
      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user tool_response model])
      tool = result.conversation.find { |e| e[:role] == "tool_response" }
      expect(tool[:content]).to include("[execute]")
      model_turn = result.conversation.find { |e| e[:role] == "model" }
      expect(model_turn[:content]).to eq("the follow-up")
    end

    it "AC#3: a mixed text + tool call in one turn dispatches the tool and returns the follow-up (text not re-emitted)" do
      install_provider!([
        { "choices" => [{ "message" => {
          "content" => "calling the tool",
          "tool_calls" => [wire_tool_call(id: "c1", name: "execute", arguments: '{"command":"x"}')]
        }}]},
        body_with_text("the answer")
      ])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      # user -> model(text+tool) -> tool_response -> model(final)
      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user model tool_response model])
      model_turns = result.conversation.select { |e| e[:role] == "model" }
      expect(model_turns.map { |e| e[:content] }).to eq(["calling the tool", "the answer"])
    end

    it "AC#4: a failing tool is captured as a result string (not a crash) and fed back" do
      install_provider!([
        body_with_tool(id: "c1", name: "execute", arguments: '{"command":"boom"}'),
        body_with_text("recovered")
      ])
      allow(fake_kernel).to receive(:dispatch_tool_call).and_raise(RuntimeError.new("disk full"))

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      tool = result.conversation.find { |e| e[:role] == "tool_response" }
      expect(tool[:content]).to include("Error: RuntimeError: disk full")
      expect(result.text).to eq("recovered")
    end

    it "AC#5: an unknown tool name is dispatched, returns the standard error, and is fed back" do
      install_provider!([
        body_with_tool(id: "c1", name: "frobnicate", arguments: '{}'),
        body_with_text("done")
      ])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      tool = result.conversation.find { |e| e[:role] == "tool_response" }
      expect(tool[:content]).to include("unknown tool 'frobnicate'")
    end

    it "AC#7: stops at max_iterations without looping forever" do
      # A tool-only response sequence would loop forever; the cap bounds it.
      install_provider!([body_with_tool(id: "c1", name: "execute", arguments: '{}')])

      result = backend.complete(messages: [{ role: "user", content: "go" }], max_iterations: 3)

      expect(result.tool_calls).to be_nil
      tool_responses = result.conversation.select { |e| e[:role] == "tool_response" }
      expect(tool_responses.length).to eq(3)
      # Criterion #7: exhausted (not errored/canceled) — the loop stopped at the
      # cap rather than finishing. The last turn was a tool call, so there is no
      # clean final answer text.
      expect(result.canceled?).to be(false)
      expect(result.exhausted?).to be(true)
      expect(result.text).to eq("")
    end

    it "AC#10: two tool calls in one turn both dispatch and both are fed back" do
      install_provider!([
        { "choices" => [{ "message" => {
          "content" => "",
          "tool_calls" => [
            wire_tool_call(id: "c1", name: "execute", arguments: '{"command":"a"}'),
            wire_tool_call(id: "c2", name: "web_fetch", arguments: '{"url":"https://x"}')
          ]
        }}]},
        body_with_text("done")
      ])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      expect(result.tool_calls).to be_nil
      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user tool_response tool_response model])
    end

    it "AC#11: a thinking-only response (no tool) breaks the loop and returns stripped text" do
      install_provider!([body_with_text("<|think|>let me reason<|think|>\nthe answer")])

      result = backend.complete(messages: [{ role: "user", content: "go" }])

      expect(result.text).to eq("the answer")
    end

    it "emits tool-call events with per-call call_index" do
      install_provider!([
        { "choices" => [{ "message" => {
          "content" => "",
          "tool_calls" => [
            wire_tool_call(id: "c1", name: "execute", arguments: '{"command":"a"}'),
            wire_tool_call(id: "c2", name: "web_fetch", arguments: '{"url":"https://x"}')
          ]
        }}]},
        body_with_text("done")
      ])

      events = []
      backend.complete(
        messages: [{ role: "user", content: "go" }],
        on_stream_event: ->(event) { events << event }
      )

      completed = events.select { |e| e[:type] == :tool_call_completed }
      expect(completed.map { |e| e[:call_index] }).to eq([1, 2])
      expect(completed.map { |e| e[:tool] }).to eq(%w[execute web_fetch])
      expect(events.any? { |e| e[:type] == :tool_dispatch_started }).to be(true)
      expect(events.any? { |e| e[:type] == :tool_call_started }).to be(true)
    end

    describe "cancellation with the loop" do
      it "AC#9: an inter-tool cancel (between generations) is caught before the next seed" do
        install_provider!([
          body_with_tool(id: "c1", name: "execute", arguments: '{"command":"first"}'),
          body_with_text("should-not-reach")
        ])
        cc = Samagotchi::Client::CancellationController.new
        # Give the cancel time to land between turn 1's dispatch and turn 2's seed.
        allow(fake_kernel).to receive(:dispatch_tool_call) do |_call|
          sleep(0.4)
          { output: "[execute] done", activity: nil }
        end

        result_holder = {}
        worker = Thread.new do
          result_holder[:result] = backend.complete(
            messages: [{ role: "user", content: "go" }],
            cancel_controller: cc
          )
        rescue StandardError => e
          result_holder[:error] = e
        end
        # Let turn 1 finish its generation + dispatch, then cancel before turn 2 seeds.
        sleep(0.15)
        cc.cancel!("between-tools")
        worker.join(5)

        expect(result_holder[:error]).to be_nil
        expect(result_holder[:result].canceled?).to be(true)
        expect(result_holder[:result].cancellation_reason).to eq("between-tools")
        expect(result_holder[:result].text).to eq("")
      end
    end
  end

  describe "#complete — model wiring" do
    it "constructs with a custom/local model name without raising" do
      expect { described_class.new(model_name: "custom-local-model") }.not_to raise_error
    end

    it "passes model_name through to the raw request body's model field" do
      install_provider!([body_with_text("ok")])

      backend.complete(messages: [{ role: "user", content: "hi" }], model_name: "override-model")

      expect(request_bodies.last[:model]).to eq("override-model")
    end
  end
end
