# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/backend"
require "samagotchi/llm/chat_loop"
require "samagotchi/hooks"
require_relative "../support/fake_chat_adapter"
require_relative "../support/fake_provider_server"

RSpec.describe Samagotchi::LLM::ChatLoop do
  # A KernelLoop stand-in for dispatch and thought stripping (Gemma-style
  # <|think|> blocks); profile-specific stripping is tested on KernelLoop.
  let(:fake_kernel) do
    kernel = double("kernel", hooks: nil)
    allow(kernel).to receive(:strip_model_thought) { |text| text.to_s.gsub(/<\|think\|>.*?<\|think\|>/m, "").strip }
    known_tools = Samagotchi::KernelLoop::TOOLS.map(&:name)
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      name = call[:name].to_s
      output = known_tools.include?(name) ? "[#{name}] done: #{call[:content]}" : "Error: unknown tool '#{name}'."
      { output: output, activity: { action: "ran #{name}", tool: name, params: nil, status: "ok" } }
    end
    kernel
  end
  let(:adapter) { FakeChatAdapter.new(FakeChatAdapter.text("hello back")) }
  let(:backend) { described_class.new(kernel: fake_kernel, adapter: adapter) }
  let(:events) { [] }

  def run(messages = [{ role: "user", content: "go" }], **options)
    backend.complete(messages: messages, model_name: "m", on_stream_event: ->(event) { events << event }, **options)
  end

  def text(value, **options) = FakeChatAdapter.text(value, **options)
  def tools(*calls, text: "") = FakeChatAdapter.tools(*calls, text: text)

  it "is a ModelBackend whose provider is :chat" do
    expect(backend).to be_a(Samagotchi::LLM::ModelBackend)
    expect(backend.provider).to eq(:chat)
  end

  it "names the model the adapter reports in :generation_completed, next to the one asked for" do
    served = FakeChatAdapter.text("hi").with(model: "vendor/served-1")
    described_class.new(kernel: fake_kernel, adapter: FakeChatAdapter.new(served))
                   .complete(messages: [{ role: "user", content: "go" }], model_name: "m", on_stream_event: ->(event) { events << event })

    expect(events.find { |event| event[:type] == :generation_completed }).to include(served_model: "vendor/served-1",
                                                                                         requested_model: "m")
  end

  describe "request" do
    it "maps engine roles to the wire (model -> assistant, user content as parts)" do
      run([{ role: "system", content: "sys" }, { role: "user", content: "hi" }, { role: "model", content: "last" }])

      expect(adapter.requests.last[:messages]).to eq([
        { role: "system", content: "sys" },
        { role: "user", content: [{ type: "text", text: "hi" }] },
        { role: "assistant", content: "last" }
      ])
    end

    it "passes multi-part user content through" do
      parts = [{ type: "text", text: "What is this?" }, { type: "image_url", image_url: { url: "data:image/png;base64,AA" } }]

      run([{ role: "user", content: parts }])

      expect(adapter.requests.last[:messages].first[:content]).to eq(parts)
    end

    it "sends the model name and every tool schema, execute with its parameters" do
      run

      request = adapter.requests.last
      expect(request[:model]).to eq("m")
      execute = request[:tools].find { |tool| tool[:function][:name] == "execute" }
      expect(execute[:function][:parameters][:properties]).to include(:command)
      expect(request[:tools].size).to eq(Samagotchi::ToolDeclarations::TOOL_SCHEMAS.size)
    end

    it "builds each request from its own messages" do
      run([{ role: "user", content: "hi" }])
      run([{ role: "user", content: "hi again" }])

      expect(adapter.requests.map { |r| r[:messages].last[:content] })
        .to eq([[{ type: "text", text: "hi" }], [{ type: "text", text: "hi again" }]])
    end
  end

  describe "a text answer" do
    it "returns a ModelResult with the text and the conversation" do
      result = run([{ role: "user", content: "hi" }])

      expect(result).to be_a(Samagotchi::LLM::ModelResult)
      expect(result.text).to eq("hello back")
      expect(result.provider).to eq(:chat)
      expect(result.tool_calls).to be_nil
      expect(result).not_to be_canceled
      expect(result).not_to be_exhausted
      expect(result.conversation).to eq([{ role: "user", content: "hi" }, { role: "model", content: "hello back" }])
    end

    it "says so when the model returns an empty answer, and keeps it out of the conversation" do
      backend.adapter = FakeChatAdapter.new(text(""))

      result = run([{ role: "user", content: "hi" }])

      expect(result.text).to eq("(the model returned an empty answer)")
      expect(result).not_to be_exhausted
      expect(result.conversation).to eq([{ role: "user", content: "hi" }])
    end

    it "calls an answer that was only thinking empty too" do
      backend.adapter = FakeChatAdapter.new(text("<|think|>hm<|think|>"))

      expect(run.text).to eq("(the model returned an empty answer)")
    end

    it "strips thought blocks from the answer" do
      adapter = FakeChatAdapter.new(text("<|think|>let me reason<|think|>\nthe answer"))
      backend.adapter = adapter

      expect(run.text).to eq("the answer")
    end

    it "returns the conversation with tool ids kept" do
      result = run([{ role: "user", content: "hi" }, { role: "tool_response", content: "out", tool_call_id: "c1" }])

      expect(result.conversation).to eq([
        { role: "user", content: "hi" }, { role: "tool_response", content: "out", tool_call_id: "c1" },
        { role: "model", content: "hello back" }
      ])
    end
  end

  describe "stream events" do
    it "streams chunks with text, thinking and content, per iteration, with the window on generation_started" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "x" }]), text("done", reasoning: "hmm"))
      allow(fake_kernel).to receive(:client).and_return(double("client", context_window: 32_768))

      run

      %i[generation_started generation_chunk generation_completed].each do |type|
        expect(events.select { |e| e[:type] == type }.map { |e| e[:iteration] }).to eq([1, 2])
      end
      expect(events.find { |e| e[:type] == :generation_started })
        .to include(context_window_tokens: 32_768, context_window_source: :server)
      chunk = events.select { |e| e[:type] == :generation_chunk }.last
      expect(chunk).to include(text: "done", thinking: "hmm", content: "hmmdone")
      expect(events.select { |e| e[:type] == :generation_completed }.last[:content_length]).to eq(4)
    end

    it "takes a remote host's window from its model list, without probing a /props it doesn't have" do
      remote = FakeChatAdapter.new(text("ok"))
      remote.define_singleton_method(:remote?) { true }
      remote.define_singleton_method(:context_window) { |model:| model == "m" ? 131_072 : nil }
      backend.adapter = remote
      allow(fake_kernel).to receive(:client).and_return(double("client", context_window: 8192))

      run

      expect(events.find { |e| e[:type] == :generation_started })
        .to include(context_window_tokens: 131_072, context_window_source: :model_list)
    end

    it "reports retries as generation_retrying" do
      backend.adapter = FakeChatAdapter.new(lambda { |on_retry:, **|
        on_retry.call(attempt: 1, max_retries: 5, next_delay: 0.5, error_class: "Errno::ECONNREFUSED", error_message: "refused")
        text("ok")
      })

      run

      expect(events.find { |e| e[:type] == :generation_retrying })
        .to include(iteration: 1, attempt: 1, next_delay: 0.5, error_class: "Errno::ECONNREFUSED")
    end

    it "fires the before/after generation hooks" do
      registry = Samagotchi::Hooks::Registry.new
      fired = []
      registry.register(:before_generation) { |event| fired << [:before, event[:iteration]] }
      registry.register(:after_generation) { |event| fired << [:after, event[:response]] }
      allow(fake_kernel).to receive(:hooks).and_return(registry)

      run

      expect(fired).to eq([[:before, 1], [:after, "hello back"]])
    end

    it "sets the turn's usage from the server's counts" do
      usage = Samagotchi::LLM::Usage.new(prompt_tokens: 300, completion_tokens: 12, source: :server)
      backend.adapter = FakeChatAdapter.new(text("ok", usage: usage))

      expect(run.usage).to eq(usage)
    end

    it "estimates the usage when the server reports none" do
      expect(run([{ role: "user", content: "a" * 40 }]).usage)
        .to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 10, completion_tokens: 3, source: :estimate))
    end
  end

  describe "tool calls" do
    it "dispatches a call, feeds the capped result back with its id, and returns the follow-up" do
      backend.adapter = adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "echo hi" }]), text("the follow-up"))

      result = run

      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user model tool_response model])
      expect(result.conversation[2][:content]).to include("[execute]")
      expect(adapter.requests.last[:messages].last).to include(role: "tool", tool_call_id: "c1")
      expect(result.text).to eq("the follow-up")
    end

    it "keeps text written with a tool call as its own model turn" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "x" }], text: "calling the tool"), text("the answer"))

      result = run

      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user model tool_response model])
      expect(result.conversation.select { |e| e[:role] == "model" }.map { |e| e[:content] }).to eq(["calling the tool", "the answer"])
    end

    it "turns a failing tool into an error result that goes back to the model" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "boom" }]), text("recovered"))
      allow(fake_kernel).to receive(:dispatch_tool_call).and_raise(RuntimeError, "disk full")

      result = run

      expect(result.conversation.find { |e| e[:role] == "tool_response" }[:content]).to include("Error: RuntimeError: disk full")
      expect(result.text).to eq("recovered")
    end

    it "feeds back the unknown-tool error" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "frobnicate", {}]), text("done"))

      expect(run.conversation.find { |e| e[:role] == "tool_response" }[:content]).to include("unknown tool 'frobnicate'")
    end

    it "dispatches parallel calls in order, with per-call events" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "a" }], ["c2", "web_fetch", { "url" => "https://x" }]),
                                            text("done"))

      result = run

      expect(result.conversation.map { |e| e[:role] }).to eq(%w[user model tool_response tool_response model])
      completed = events.select { |e| e[:type] == :tool_call_completed }
      expect(completed.map { |e| [e[:call_index], e[:tool]] }).to eq([[1, "execute"], [2, "web_fetch"]])
      expect(events.map { |e| e[:type] }).to include(:tool_dispatch_started, :tool_call_started, :tool_dispatch_completed)
    end

    it "stops at max_iterations, exhausted, with no final text" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", {}]))

      result = run(max_iterations: 3)

      expect(result.conversation.count { |e| e[:role] == "tool_response" }).to eq(3)
      expect(result).to be_exhausted
      expect(result).not_to be_canceled
      expect(result.text).to eq("")
    end
  end

  describe "tool call ids" do
    it "records the assistant's calls (even without text) and each result's id in the conversation" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "echo hi" }]), text("done"))

      result = run

      expect(result.conversation[1]).to eq(role: "model", content: "",
                                            tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "echo hi" } }])
      expect(result.conversation[2]).to include(role: "tool_response", tool_call_id: "c1")
    end

    it "sends the assistant's tool_calls paired with the tool messages" do
      backend.adapter = adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "echo hi" }], text: "checking"), text("done"))

      run

      assistant, tool = adapter.requests.last[:messages].last(2)
      expect(assistant).to eq(role: "assistant", content: "checking", tool_calls: [
        { id: "c1", type: "function", function: { name: "execute", arguments: '{"command":"echo hi"}' } }
      ])
      expect(tool).to include(role: "tool", tool_call_id: "c1")
    end

    it "replays a saved turn's calls and ids" do
      history = [{ role: "user", content: "go" },
                 { role: "model", content: "", tool_calls: [{ id: "c9", name: "read", arguments: { "path" => "x" } }] },
                 { role: "tool_response", content: "[read]\nx", tool_call_id: "c9" },
                 { role: "model", content: "read it" }, { role: "user", content: "again" }]

      run(history)

      wire = adapter.requests.last[:messages]
      expect(wire[1]).to include(role: "assistant", content: nil)
      expect(wire[1][:tool_calls].first).to include(id: "c9")
      expect(wire[2]).to eq(role: "tool", content: "[read]\nx", tool_call_id: "c9")
    end

    it "sends a tool result without an id (native or old history) as a user message" do
      run([{ role: "user", content: "go" }, { role: "model", content: "<|tool_call>call:read{path: \"x\"}<tool_call|>" },
           { role: "tool_response", content: "[read]\nx" }])

      expect(adapter.requests.last[:messages].last).to eq(role: "user", content: "[tool results]\n[read]\nx")
    end

    it "flattens calls and results that don't pair up, so one broken turn can't fail every request" do
      run([{ role: "user", content: "go" },
           { role: "model", content: "trying", tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "ls" } }] },
           { role: "user", content: "never mind" },
           { role: "tool_response", content: "[execute]\nlate", tool_call_id: "c7" }])

      wire = adapter.requests.last[:messages]
      expect(wire[1]).to eq(role: "assistant", content: %(trying\n[tool call] execute {"command":"ls"}))
      expect(wire.last).to eq(role: "user", content: "[tool results]\n[execute]\nlate")
      expect(wire.none? { |m| m.key?(:tool_calls) || m[:role] == "tool" }).to be(true)
    end

    it "keeps multi-part user content in the returned conversation" do
      parts = [{ type: "text", text: "look" }]

      expect(run([{ role: "user", content: parts }]).conversation.first[:content]).to eq(parts)
    end
  end

  describe "pending input" do
    it "merges queued steering into the conversation and keeps going after a clean answer" do
      backend.adapter = adapter = FakeChatAdapter.new(text("first"), text("second"))
      queue = [[], ["also this"], []]

      result = run(pending_input: -> { queue.shift || [] })

      expect(events.find { |e| e[:type] == :pending_input_merged }).to include(content: "also this")
      expect(adapter.requests.last[:messages].last).to eq(role: "user", content: [{ type: "text", text: "also this" }])
      expect(result.text).to eq("second")
    end

    it "names the answer a merge follows on :pending_input_merged" do
      backend.adapter = FakeChatAdapter.new(text("<|think|>hm<|think|>first"), text("second"))
      queue = [[], ["also this"], []]

      run(pending_input: -> { queue.shift || [] })

      expect(events.find { |e| e[:type] == :pending_input_merged }).to include(answer: "first", content: "also this")
    end

    it "keeps the answer a merge follows, so the model sees what it said" do
      backend.adapter = adapter = FakeChatAdapter.new(text("first"), text("second"))
      queue = [[], ["also this"], []]

      result = run(pending_input: -> { queue.shift || [] })

      expect(adapter.requests.last[:messages].last(2)).to eq([{ role: "assistant", content: "first" },
                                                              { role: "user", content: [{ type: "text", text: "also this" }] }])
      expect(result.conversation.map { |m| [m[:role], m[:content]] }.last(3))
        .to eq([["model", "first"], ["user", "also this"], ["model", "second"]])
    end
    it "leaves input queued after a cancel instead of merging it into the dying turn" do
      controller = Samagotchi::CancellationController.new
      queue = []
      backend.adapter = FakeChatAdapter.new(text("answer"))
      # Ctrl-C lands as the answer ends; the line comes right after it.
      allow(backend.adapter).to receive(:chat).and_wrap_original do |original, **kwargs|
        original.call(**kwargs).tap do
          controller.cancel!(:ctrl_c)
          queue << "sent after ctrl-c"
        end
      end

      result = run(pending_input: -> { queue.empty? ? [] : [queue.shift] }, cancel_controller: controller)

      expect(result.text).to eq("answer")
      expect(events.map { |e| e[:type] }).not_to include(:pending_input_merged)
      expect(queue).to eq(["sent after ctrl-c"])
    end
  end

  describe "cancel" do
    let(:controller) { Samagotchi::CancellationController.new }

    it "returns a canceled result when cancelled before the request" do
      controller.cancel!(:manual)

      result = run(cancel_controller: controller)

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:manual)
      expect(result.conversation).to eq([{ role: "user", content: "go" }])
      expect(adapter.requests).to be_empty
    end

    it "keeps the text streamed before a cancel, marked interrupted" do
      backend.adapter = FakeChatAdapter.new(lambda { |on_delta:, **|
        on_delta.call(content: "Let me check the fi", reasoning: "", payload: {})
        raise Samagotchi::LLM::RequestCancelled.new(:ctrl_c)
      })

      result = run(cancel_controller: controller)

      expect(result).to be_canceled
      expect(events.last).to include(type: :generation_cancelled, reason: :ctrl_c)
      expect(result.conversation.last).to eq(role: "model", content: "Let me check the fi\n[interrupted]", interrupted: true)
    end

    it "catches a cancel between tool calls before the next request" do
      backend.adapter = adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "first" }]), text("should-not-reach"))
      allow(fake_kernel).to receive(:dispatch_tool_call) do
        controller.cancel!("between-tools")
        { output: "[execute] done", activity: nil }
      end

      result = run(cancel_controller: controller)

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq("between-tools")
      expect(adapter.requests.size).to eq(1)
    end

    # The real adapter and HTTP layer: the socket is closed under the reader,
    # so a cancel lands on the main thread too (the old ruby_llm backend could not).
    it "cancels a real stream on the calling thread" do
      FakeProviderServer.without_webmock do
        server = FakeProviderServer.start
        events_of_text = FakeProviderServer.sse_events(FakeProviderServer.fixture("text_stream.sse"))
        server.enqueue("/v1/chat/completions", sse: events_of_text.first(3), hold: true)
        backend.adapter = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box")
        canceller = Thread.new { sleep 0.3; controller.cancel!(:ctrl_c) }

        result = run(cancel_controller: controller)

        expect(Thread.current).to eq(Thread.main)
        expect(result).to be_canceled
        expect(result.cancellation_reason).to eq(:ctrl_c)
      ensure
        canceller&.join
        server&.stop
      end
    end
  end

  describe "a failed turn" do
    it "hands the conversation built so far back on the error" do
      backend.adapter = FakeChatAdapter.new(tools(["c1", "execute", { "command" => "true" }]),
                                            Samagotchi::LLM::ServerError.new("boom", host: "box"))

      expect { run }.to raise_error(Samagotchi::LLM::ServerError) { |error|
        expect(error.partial_conversation.map { |m| m[:role] }).to eq(%w[user model tool_response])
      }
    end
  end
end
