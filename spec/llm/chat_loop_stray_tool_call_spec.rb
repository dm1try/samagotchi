# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/chat_loop"
require "samagotchi/llm/stray_tool_call"
require "samagotchi/session"
require "samagotchi/tools/write"
require "fileutils"
require "tmpdir"
require_relative "../support/fake_chat_adapter"
require_relative "../support/test_kernel"

# A reply that is nothing but a tool call written as text: the host's parser
# could not read the block, so it came back as content with no tool calls (a
# Qwen flavour that writes `<parameter=execute>` where `<function=execute>`
# belongs — the pad-3 eval run's iteration 70). ChatLoop does not take it as
# the answer: the text never joins the conversation, the reply is asked for
# once more with a hidden nudge at the retry temperature, and a second one
# fails the turn with LLM::MalformedGeneration. KernelLoop's own path is
# untouched, and nothing is ever guessed from the block.
RSpec.describe Samagotchi::LLM::ChatLoop, "a reply that is only a tool call" do
  # The whole reply, as it was saved in that session (docs/internals/engine.md).
  STRAY = <<~TEXT
    <tool_call>
    <parameter=execute>
    <parameter=command>
    cd /private/tmp/... && rg -n "..." spec | head -20 && rg -n "why:" spec | head -20
    </parameter>
    </function>
    </tool_call>
  TEXT

  let(:nudge) { Samagotchi::TurnNote.malformed_retry }
  let(:fake_kernel) do
    kernel = test_kernel
    allow(kernel).to receive(:strip_model_thought) { |text| text.to_s }
    allow(kernel).to receive(:dispatch_tool_call) do |call|
      { output: "[#{call[:name]}] done: #{call[:content]}",
        activity: { action: "ran #{call[:name]}", tool: call[:name], params: nil, status: "ok" } }
    end
    kernel
  end
  let(:events) { [] }
  let(:backend) { described_class.new(kernel: fake_kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("hi"))) }

  def text(value, **options) = FakeChatAdapter.text(value, **options)
  def tools(*calls, text: "") = FakeChatAdapter.tools(*calls, text: text)

  def run(messages = [{ role: "user", content: "go" }], **options)
    backend.complete(messages: messages, model_name: "flash-next",
                     on_stream_event: ->(event) { events << event }, **options)
  end

  before { allow(Samagotchi::Log).to receive(:warn) }

  def types = events.map { |event| event[:type] }

  def contents(conversation)
    conversation.map { |message| message[:content].to_s }.join
  end

  describe "the retry" do
    it "asks again with a hidden nudge at the retry temperature, and the bad reply never enters the conversation" do
      backend.adapter = adapter = FakeChatAdapter.new(text(STRAY), text("PONG"))

      result = run([{ role: "user", content: "hi" }])

      expect(result.text).to eq("PONG")
      expect(result).not_to be_empty_answer
      expect(result.conversation).to eq([{ role: "user", content: "hi" }, nudge,
                                         { role: "model", content: "PONG", at: message_at }])
      expect(contents(result.conversation)).not_to include("<tool_call>")
      expect(adapter.requests.map { |request| request[:options] }).to eq([{}, { temperature: 0.6 }])
      # The retry's prompt is the same conversation with the nudge added at
      # the end: nothing of the bad reply is in it (the prompt cache stays
      # append-only).
      first = adapter.requests.first[:messages]
      expect(adapter.requests.last[:messages].first(first.length)).to eq(first)
      expect(adapter.requests.last[:messages].last).to eq(role: "system", content: nudge[:content])
      expect(result.empty_steps).to eq([{ role: "model", content: STRAY, at: message_at }])
    end

    it "says so in the stream: the step's streamed text is void, and the UIs call it a malformed answer" do
      backend.adapter = FakeChatAdapter.new(text(STRAY), text("PONG"))

      run

      expect(events.select { |event| event[:type] == :generation_retrying })
        .to eq([{ type: :generation_retrying, iteration: 1, restarted: true, shape: "tool_call" }])
      expect(events.count { |event| event[:type] == :empty_answer_retry }).to eq(1)
      expect(events.find { |event| event[:type] == :empty_answer_retry })
        .to include(iteration: 1, attempt: 1, of: 1, malformed: true, finish_reason: "stop")
      # The generation is asked for again: two generations, one turn.
      expect(types.count(:generation_started)).to eq(2)
    end

    it "ends cancelled when the Stop lands on the first stray reply, rather than failing the turn" do
      controller = Samagotchi::CancellationController.new
      backend.adapter = adapter = FakeChatAdapter.new(text(STRAY), text("PONG"))

      # The Stop arrives as the reply comes in: the cancel is set before the
      # retry decision is made.
      result = backend.complete(messages: [{ role: "user", content: "go" }], model_name: "flash-next",
                                cancel_controller: controller,
                                on_stream_event: lambda { |event|
                                  events << event
                                  controller.cancel!(:manual) if event[:type] == :generation_completed && !controller.cancelled?
                                })

      expect(result).to be_canceled
      expect(result.cancellation_reason).to eq(:manual)
      expect(result.text).to eq("")
      # Nothing was asked again and nothing was raised: the block is not the
      # second one in a row.
      expect(adapter.requests.length).to eq(1)
      expect(contents(result.conversation)).not_to include("<tool_call>")
      expect(types).not_to include(:generation_retrying, :empty_answer_retry)
      expect(types).to include(:generation_cancelled)
    end

    it "logs what the host sent, with the shape, the finish reason and the tail" do
      backend.adapter = FakeChatAdapter.new(text(STRAY, reasoning: "thinking first"),
                                            text("PONG", usage: Samagotchi::LLM::Usage.new(prompt_tokens: 10, completion_tokens: 4, source: :server)))

      run

      expect(Samagotchi::Log).to have_received(:warn).with(
        :model, "generation_malformed",
        hash_including(iteration: 1, shape: "tool_call", finish_reason: "stop", served_model: nil, retried: true,
                       payload: a_string_matching(%r{\A<tool_call>\n<parameter=execute>[\s\S]*</function>\n</tool_call>}))
      )
    end

    it "keeps its own budget: retry.empty_answer 0 does not turn the retry off" do
      original = ENV.fetch("SAMAGOTCHI_RETRY_EMPTY_ANSWER", nil)
      ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = "0"
      backend.adapter = FakeChatAdapter.new(text(STRAY), text("answered"))

      result = run

      expect(result.text).to eq("answered")
      expect(result.conversation.last[:content]).to eq("answered")
      expect(events.count { |event| event[:type] == :empty_answer_retry }).to eq(1)
    ensure
      original.nil? ? ENV.delete("SAMAGOTCHI_RETRY_EMPTY_ANSWER") : ENV["SAMAGOTCHI_RETRY_EMPTY_ANSWER"] = original
    end

    it "spends one iteration of max_iterations, and with none left saves no answer and no block" do
      backend.adapter = adapter = FakeChatAdapter.new(text(STRAY), text("PONG"))

      result = run(max_iterations: 1)

      expect(result.text).to eq("")
      expect(result).to be_exhausted
      expect(result.conversation).to eq([{ role: "user", content: "go" }, nudge])
      expect(contents(result.conversation)).not_to include("<tool_call>")
      expect(adapter.requests.length).to eq(1)
    end

    it "lets queued input go first, in place of the nudge, without the block as the answer" do
      backend.adapter = FakeChatAdapter.new(text(STRAY), text("answered"))
      calls = []
      items = [[], [{ text: "check in", source: "check-in" }]]

      result = run(pending_input: lambda { |at_answer: false|
        calls << at_answer
        items.shift || []
      })

      expect(calls).to eq([false, false, false, true])
      expect(result.text).to eq("answered")
      expect(result.conversation.map { |message| message.slice(:role, :kind, :content) })
        .to eq([{ role: "user", content: "go" }, { role: "user", kind: "steer", content: "check in" },
                { role: "model", content: "answered" }])
      merged = events.find { |event| event[:type] == :pending_input_merged }
      expect(merged[:answer]).to be_nil
      expect(events.map { |event| event[:type] }).not_to include(:empty_answer_retry)
    end

    it "gives a slip later in the turn its own retry, once a real tool call came between" do
      backend.adapter = adapter = FakeChatAdapter.new(text(STRAY), tools(["c1", "read", { "path" => "a.rb" }]), text(STRAY), text("PONG"))

      expect { run }.not_to raise_error
      expect(adapter.requests.length).to eq(4)
    end

    it "fails the turn on the second one in a row, keeping the steps the turn already got" do
      backend.adapter = adapter = FakeChatAdapter.new(tools(["c1", "read", { "path" => "a.rb" }]), text(STRAY), text(STRAY))

      expect { run }.to raise_error(Samagotchi::LLM::MalformedGeneration) do |error|
        # ChatLoop attaches the conversation so far to every error it raises,
        # as it does for the provider errors, so the turn's tool steps stay.
        expect(error.partial_conversation.map { |message| message[:role] }).to eq(%w[user model tool_response])
        expect(error.partial_conversation[1][:tool_calls]).to eq([{ id: "c1", name: "read", arguments: { "path" => "a.rb" } }])
        expect(contents(error.partial_conversation)).not_to include("<tool_call>")
        expect(error.summary).to include("could not read")
        expect(error.summary).not_to include("cache")
        expect(error.kind).to eq(:protocol)
        expect(error.retryable?).to be false
      end
      expect(adapter.requests.length).to eq(3)
      expect(types.count(:tool_call_started)).to eq(1)
    end
  end

  describe "answers that stay answers" do
    # The cost on the happy path: one cheap test, no note, no event, no
    # request.
    it "takes no new path for a plain answer" do
      backend.adapter = adapter = FakeChatAdapter.new(text("the commit is done"))

      result = run

      expect(result.text).to eq("the commit is done")
      expect(adapter.requests.length).to eq(1)
      expect(result.conversation).to eq([{ role: "user", content: "go" }, { role: "model", content: "the commit is done", at: message_at }])
      expect(result.empty_steps).to eq([])
      expect(types).not_to include(:generation_retrying, :empty_answer_retry)
      expect(Samagotchi::Log).not_to have_received(:warn).with(:model, "generation_malformed", anything)
    end

    it "says nothing on a tool-calling step either" do
      backend.adapter = adapter = FakeChatAdapter.new(tools(["c1", "read", { "path" => "a.rb" }], text: "let me read it"), text("done"))

      run

      expect(adapter.requests.length).to eq(2)
      expect(types).not_to include(:generation_retrying, :empty_answer_retry)
      expect(Samagotchi::Log).not_to have_received(:warn).with(:model, "generation_malformed", anything)
    end

    it "keeps prose about the syntax, a fenced example and inline code as the answer" do
      answers = [
        "I ran <tool_call> for that earlier; the count is 7.",
        "The wire looks like this:\n```\n<tool_call>\n<parameter=execute>\n</parameter>\n</tool_call>\n```\nNothing else to run.",
        "```\n<tool_call>\n<parameter=execute>\n</parameter>\n</tool_call>\n```",
        "The tag is `<parameter=execute>`, not `<function=execute>`.",
        "Now the commit:\n<tool_call>\n<function=execute>\n</function>\n</tool_call>",
        "<tool_call>\n<parameter=execute>",
        "<function=task_list></parameter>"
      ]

      answers.each do |answer|
        events.clear
        backend.adapter = FakeChatAdapter.new(text(answer))

        result = run

        expect(result.text).to eq(answer)
        expect(events.map { |event| event[:type] }).not_to include(:generation_retrying, :empty_answer_retry)
      end
    end

    it "asks again for a block that carries no inner tags" do
      ["<function=task_list></function>", "<function=execute>{\"command\":\"ls\"}</function>",
       "<parameter=execute>ls</parameter>", "<tool_call>{\"name\":\"x\"}</tool_call>"].each do |block|
        events.clear
        backend.adapter = FakeChatAdapter.new(text(block), text("PONG"))

        result = run

        expect(result.text).to eq("PONG")
        expect(events.map { |event| event[:type] }).to include(:generation_retrying)
      end
    end
  end
end

RSpec.describe Samagotchi::LLM::StrayToolCall do
  BLOCK = "<tool_call>\n<parameter=execute>\n<parameter=command>\nls\n</parameter>\n</function>\n</tool_call>"

  it "names the block a reply that is only one closed call" do
    expect(described_class.shape(BLOCK)).to eq("tool_call")
    expect(described_class.shape("  \n<tool_call>\n<function=execute>\n<parameter=path>\na.rb\n</parameter>\n</function>\n</tool_call>  \n")).to eq("tool_call")
    expect(described_class.shape("<function=execute>\n<parameter=command>\nls\n</parameter>\n</function>")).to eq("function")
    expect(described_class.shape("<parameter=execute>\n<parameter=command>\nls\n</parameter>\n</parameter>")).to eq("parameter")
  end

  # The block needs nothing inside it: the close is the opener's own.
  it "names a block with no inner tags the same way" do
    expect(described_class.shape("<function=task_list></function>")).to eq("function")
    expect(described_class.shape("<function=execute>{\"command\":\"ls\"}</function>")).to eq("function")
    expect(described_class.shape("<parameter=execute>ls</parameter>")).to eq("parameter")
    expect(described_class.shape("<tool_call>{\"name\":\"x\"}</tool_call>")).to eq("tool_call")
    # The flavour that mixes the tags also closes a `<parameter=` call with `</function>`.
    expect(described_class.shape("<parameter=execute>ls</function>")).to eq("parameter")
  end

  it "reads an answer as an answer" do
    [nil, "", "  ", "hello", "I ran <tool_call> and it worked.",
     "The tag is `<parameter=execute>`.",
     "```\n<tool_call>\n<function=execute>\n</function>\n</tool_call>\n```",
     "Now the commit:\n<tool_call>\n<function=execute>\n</function>\n</tool_call>",
     "<tool_call>\n<function=execute>\n</function>\n</tool_call>\nand then I committed",
     "<tool_call>", "<tool_call>\n<function=execute>", "\"<tool_call>\n<function=x>\n</function>\n</tool_call>\"",
     # A close that is not the opener's own, or no close at all.
     "<function=task_list></parameter>", "<tool_call>\n<parameter=execute>ls</parameter>",
     "<function=execute>ls"].each do |text|
      expect(described_class.shape(text)).to be_nil
    end
  end

  it "keeps the tail the log wants" do
    long = "x" * 500
    expect(described_class.tail(long)).to eq("x" * 400)
    expect(described_class.tail(BLOCK)).to eq(BLOCK)
  end
end
