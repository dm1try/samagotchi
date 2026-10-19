# frozen_string_literal: true

require "spec_helper"
require "json"

require "samagotchi/bridge"
require "samagotchi/llm/anthropic_assembly"

RSpec.describe Samagotchi::Bridge::ClientEvent do
  def fixture_payloads(path)
    File.readlines(File.expand_path("../fixtures/providers/#{path}", __dir__))
        .filter_map { |line| JSON.parse(line.delete_prefix("data: ")) if line.start_with?("data: {") }
  end

  def chunk(payload, **fields)
    { type: :generation_chunk, iteration: 1, content: "x", text: "x", thinking: "", payload: payload, event_seq: 7, **fields }
  end

  def counts_of(payload) = described_class.project(chunk(payload))[:counts]

  # Anthropic stream events as AnthropicAssembly#with_usage hands them on.
  def assembled(path)
    assembly = Samagotchi::LLM::AnthropicAssembly.new
    fixture_payloads(path).map do |event|
      assembly.add(event)
      assembly.with_usage(event)
    end
  end

  describe "llama.cpp /completion (the real cached-stream fixture)" do
    let(:payloads) { fixture_payloads("llamacpp/completion_cached_stream.sse") }

    it "counts a mid-stream chunk's prompt plus what it predicted so far" do
      expect(counts_of(payloads[3])).to eq(prompt_tokens: 489, completion_tokens: 4, total_tokens: 493)
    end

    # timings.prompt_n is the uncached part (4): tokens_evaluated (the whole
    # prompt, cache included) must be read first (TokenUsage.from_payload).
    it "counts the last chunk's prompt with its cached tokens, not timings.prompt_n" do
      last = payloads.last
      expect(last.dig("timings", "prompt_n")).to eq(4)
      expect(counts_of(last)).to eq(prompt_tokens: 489, completion_tokens: 8, total_tokens: 497)
    end
  end

  it "takes a window and n_past the payload reports itself (hand-written)" do
    expect(counts_of({ "n_ctx" => 32_768, "n_past" => 500, "tokens_evaluated" => 480, "tokens_predicted" => 20 }))
      .to eq(prompt_tokens: 480, completion_tokens: 20, total_tokens: 500, context_window_tokens: 32_768)
  end

  it "reads OpenAI's final usage (hand-written)" do
    payload = { "choices" => [], "usage" => { "prompt_tokens" => 295, "completion_tokens" => 18, "total_tokens" => 313 } }
    expect(counts_of(payload)).to eq(prompt_tokens: 295, completion_tokens: 18, total_tokens: 313)
  end

  it "reads OpenRouter's usage with prompt_tokens_details, leaving its extras out (hand-written)" do
    payload = { "choices" => [], "usage" => { "prompt_tokens" => 1200, "completion_tokens" => 40, "total_tokens" => 1240,
                                              "cost" => 0.0012,
                                              "prompt_tokens_details" => { "cached_tokens" => 1024 } } }
    expect(counts_of(payload)).to eq(prompt_tokens: 1200, completion_tokens: 40, total_tokens: 1240)
  end

  describe "Anthropic (AnthropicAssembly#with_usage)" do
    it "counts the cache read and write into the prompt" do
      events = assembled("anthropic/fireworks_text_stream.hand-written.sse")
      delta = events.find { |e| e["type"] == "message_delta" }
      expect(counts_of(delta)).to eq(prompt_tokens: 812, completion_tokens: 9, total_tokens: 821)
    end

    it "gives Fireworks' zero message_start no counts" do
      start = assembled("anthropic/fireworks_text_stream.hand-written.sse").find { |e| e["type"] == "message_start" }
      projected = described_class.project(chunk(start))
      expect(projected).not_to have_key(:counts)
    end

    it "counts a real stream's message_start and its last message_delta" do
      events = assembled("anthropic/splash_thinking_stream.sse")
      expect(counts_of(events.find { |e| e["type"] == "message_start" }))
        .to eq(prompt_tokens: 22, total_tokens: 22)
      expect(counts_of(events.find { |e| e["type"] == "message_delta" }))
        .to eq(prompt_tokens: 22, completion_tokens: 1179, total_tokens: 1201)
    end
  end

  it "adds no counts to a plain delta" do
    event = chunk({ "choices" => [{ "delta" => { "content" => "hi" } }] })
    expect(described_class.project(event)).not_to have_key(:counts)
  end

  it "drops the provider's payload and the raw content, and keeps every other field, event_seq included" do
    projected = described_class.project(chunk(fixture_payloads("llamacpp/completion_cached_stream.sse").last,
                                              tool_call: true, later_field: 1))
    expect(projected.keys).to contain_exactly(:type, :iteration, :text, :thinking, :tool_call, :later_field, :event_seq, :counts)
  end

  it "drops them from a chunk without counts too" do
    projected = described_class.project(chunk({ "choices" => [] }))
    expect(projected).to eq(type: :generation_chunk, iteration: 1, text: "x", thinking: "", event_seq: 7)
  end

  it "never changes the event it is given" do
    event = chunk(fixture_payloads("llamacpp/completion_cached_stream.sse").last)
    before = Marshal.load(Marshal.dump(event))
    described_class.project(event)
    expect(event).to eq(before)
  end

  it "drops a tool call from the client event without changing the raw event" do
    call = { name: "write", content: "x" * 20_000 }
    event = { type: :tool_call_started, iteration: 2, call_index: 1, tool: "write", call: call,
              params: "path=large.txt", view: { description: "Writing" }, ref: "file", title: "Write",
              event_seq: 9 }

    projected = described_class.project(event)

    expect(projected).to eq(event.except(:call))
    expect(projected).not_to have_key(:call)
    expect(event[:call]).to equal(call)
  end

  it "drops the completed result while keeping the turn summary" do
    summary = { output: "the answer", empty_answer: nil }
    event = { type: :turn_completed, result: "the answer", turn_summary: summary, display_pending: true, event_seq: 10 }

    projected = described_class.project(event)

    expect(projected).to eq(event.except(:result))
    expect(projected[:turn_summary]).to equal(summary)
    expect(event[:result]).to eq("the answer")
  end

  it "hands back every other event as the same object" do
    event = { type: :generation_completed, iteration: 1, payload: { "usage" => { "total_tokens" => 5 } }, event_seq: 3 }
    expect(described_class.project(event)).to be(event)
    %i[tool_call_completed turn_canceled turn_failed].each do |type|
      other = { type: type, event_seq: 4 }
      expect(described_class.project(other)).to be(other)
    end
    expect(described_class.project("not a hash")).to eq("not a hash")
  end

  it "matches the type as a string too" do
    expect(described_class.project({ type: "generation_chunk", payload: { "usage" => { "total_tokens" => 5 } } })[:counts])
      .to eq(total_tokens: 5)
  end
end
