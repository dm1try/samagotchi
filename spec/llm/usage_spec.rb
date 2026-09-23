# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/usage"
require "samagotchi/llm/native_backend"
require "samagotchi/kernel_loop"

RSpec.describe Samagotchi::LLM::Usage do
  it "reads server counts from a payload, through TokenUsage" do
    usage = described_class.from_payload({ "usage" => { "prompt_tokens" => 314, "completion_tokens" => 75 } })

    expect(usage).to eq(described_class.new(prompt_tokens: 314, completion_tokens: 75, source: :server))
    expect(usage.total_tokens).to eq(389)
  end

  it "is nil for a payload without counts" do
    expect(described_class.from_payload({ "content" => "hi" })).to be_nil
  end

  it "estimates from text at 4 chars per token" do
    expect(described_class.estimate(prompt_text: "a" * 40, completion_text: "b" * 9))
      .to eq(described_class.new(prompt_tokens: 10, completion_tokens: 3, source: :estimate))
  end

  it "has a zero value that says there was nothing to count" do
    expect(described_class.none).to eq(described_class.new(prompt_tokens: 0, completion_tokens: 0, source: :none))
  end

  describe Samagotchi::LLM::UsageCollector do
    subject(:collector) { described_class.new }

    def generation(*payloads, content: "")
      collector.observe(type: :generation_started)
      payloads.each { |payload| collector.observe(type: :generation_chunk, content: content, payload: payload) }
      collector.observe(type: :generation_completed)
    end

    # Server counts are cumulative per request: the prompt grows across a
    # turn's generations, so the last one counts; completions add up.
    it "takes the last generation's prompt tokens and sums the completion tokens" do
      generation({ "timings" => { "prompt_n" => 100, "predicted_n" => 5 } }, { "timings" => { "prompt_n" => 100, "predicted_n" => 20 } })
      generation({ "usage" => { "prompt_tokens" => 180, "completion_tokens" => 7 } })

      expect(collector.usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 180, completion_tokens: 27, source: :server))
    end

    it "estimates when no chunk carried counts" do
      generation({}, content: "a" * 8)

      expect(collector.usage(prompt_text: "p" * 20))
        .to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 5, completion_tokens: 2, source: :estimate))
    end

    it "is none when nothing was generated" do
      expect(collector.usage).to eq(Samagotchi::LLM::Usage.none)
    end
  end
end

RSpec.describe Samagotchi::LLM::NativeBackend do
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:backend) { described_class.new(kernel: kernel) }

  def kernel_result
    Samagotchi::KernelLoop::Result.new(output: "done", conversation: [], exhausted: false, pending_tool_calls: false,
                                       tool_activity: [], canceled: false)
  end

  it "sets the turn's usage from the stream and still forwards every event" do
    allow(kernel).to receive(:run) do |_messages, on_stream_event:, **|
      on_stream_event.call(type: :generation_started, iteration: 1)
      on_stream_event.call(type: :generation_chunk, iteration: 1, content: "done",
                           payload: { "timings" => { "prompt_n" => 50, "predicted_n" => 3 } })
      kernel_result
    end
    events = []

    result = backend.complete(messages: [{ role: "user", content: "hi" }], on_stream_event: ->(event) { events << event })

    expect(result.usage).to eq(Samagotchi::LLM::Usage.new(prompt_tokens: 50, completion_tokens: 3, source: :server))
    expect(events.map { |event| event[:type] }).to eq(%i[generation_started generation_chunk])
  end

  it "never leaves usage nil" do
    allow(kernel).to receive(:run).and_return(kernel_result)

    expect(backend.complete(messages: [{ role: "user", content: "hi" }]).usage).to eq(Samagotchi::LLM::Usage.none)
  end
end
