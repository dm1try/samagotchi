# frozen_string_literal: true

require "samagotchi/llm/backend"

RSpec.describe Samagotchi::LLM::NativeInContextBackend do
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:kernel_result) do
    Samagotchi::KernelLoop::Result.new(
      output: "hello back",
      conversation: [{ role: "user", content: "hi" }, { role: "model", content: "hello back" }],
      exhausted: false,
      pending_tool_calls: false,
      tool_activity: [],
      canceled: false,
      cancellation_reason: nil
    )
  end

  it "wraps the native loop result in a ModelResult (text, tool_calls nil, provider :native)" do
    allow(kernel).to receive(:run).and_return(kernel_result)
    backend = described_class.new(kernel: kernel)

    result = backend.complete(messages: [{ role: "user", content: "hi" }])

    expect(result).to be_a(Samagotchi::LLM::ModelResult)
    expect(result.text).to eq("hello back")
    expect(result.output).to eq("hello back")
    expect(result.tool_calls).to be_nil
    expect(result.provider).to eq(:native)
    expect(result.conversation).to eq(kernel_result.conversation)
    expect(result.canceled?).to be(false)
  end

  it "forwards the streaming/cancel/model-override passthroughs to KernelLoop#run" do
    captured = {}
    allow(kernel).to receive(:run) do |_messages, **kwargs|
      captured[:kwargs] = kwargs
      kernel_result
    end
    backend = described_class.new(kernel: kernel)

    backend.complete(
      messages: [{ role: "user", content: "hi" }],
      max_iterations: 7,
      on_stream_event: -> {},
      cancel_controller: :cc,
      model_name: "qwen36",
      max_tool_output_chars: 123
    )

    expect(captured[:kwargs]).to include(
      max_iterations: 7,
      on_stream_event: anything,
      cancel_controller: :cc,
      model_name: "qwen36",
      max_tool_output_chars: 123
    )
  end

  it "copies canceled? and cancellation_reason from a canceled kernel result" do
    canceled = Samagotchi::KernelLoop::Result.new(
      output: "",
      conversation: [],
      exhausted: false,
      pending_tool_calls: false,
      tool_activity: [],
      canceled: true,
      cancellation_reason: :user_interrupt
    )
    allow(kernel).to receive(:run).and_return(canceled)
    backend = described_class.new(kernel: kernel)

    result = backend.complete(messages: [])
    expect(result.canceled?).to be(true)
    expect(result.cancellation_reason).to eq(:user_interrupt)
  end

  it "returns a valid ModelResult shape for empty messages" do
    allow(kernel).to receive(:run).and_return(
      Samagotchi::KernelLoop::Result.new(output: "", conversation: [], tool_activity: [])
    )
    result = described_class.new(kernel: kernel).complete(messages: [])
    expect(result).to be_a(Samagotchi::LLM::ModelResult)
    expect(result.text).to eq("")
    expect(result.tool_calls).to be_nil
    expect(result.conversation).to eq([])
  end
end
