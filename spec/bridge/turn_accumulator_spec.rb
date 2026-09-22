# frozen_string_literal: true

require "json"
require "samagotchi/bridge/turn_accumulator"

RSpec.describe Samagotchi::Bridge::TurnAccumulator do
  subject(:acc) { described_class.new }

  def feed(*events)
    events.each do |event|
      @seq = (@seq || 0) + 1
      acc.call(event.merge(event_seq: @seq))
    end
  end

  it "has nothing before a turn starts" do
    expect(acc.current_turn).to be_nil
    expect(acc.queued).to eq([])
  end

  it "folds a running turn: prompt, origin, thinking and text in order, tool calls" do
    feed(
      { type: :turn_started, session_id: "s", prompt: "hi", origin: { client_id: "web:1", enqueued_id: "e1" } },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, content: "<think>a", thinking: "a", text: "" },
      { type: :generation_chunk, iteration: 1, content: "b", thinking: "b", text: "" },
      { type: :generation_chunk, iteration: 1, content: "</think>Hel", thinking: "", text: "Hel" },
      { type: :generation_chunk, iteration: 1, content: "lo", thinking: "", text: "lo" },
      { type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute", params: "ls", call: { name: "execute" } },
      { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "execute", output: "a.txt", output_truncated: false,
        activity: { status: "ok" } },
      { type: :generation_started, iteration: 2 },
      { type: :generation_chunk, iteration: 2, content: "Done" } # a profile that doesn't split thinking
    )

    turn = acc.current_turn
    expect(turn).to include(prompt: "hi", origin: { client_id: "web:1", enqueued_id: "e1" }, event_seq: 10)
    expect(turn[:parts]).to eq([
      { kind: "thinking", iteration: 1, text: "ab" },
      { kind: "text", iteration: 1, text: "Hello" },
      { kind: "tool", iteration: 1, call_index: 1, tool: "execute", params: "ls", status: "ok",
        output: "a.txt", output_truncated: false },
      { kind: "text", iteration: 2, text: "Done" }
    ])
    expect { JSON.generate(turn) }.not_to raise_error
  end

  it "caps a tool's output at the event cap" do
    feed({ type: :turn_started, prompt: "hi" },
         { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read" },
         { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", output: "x" * 20_000, activity: {} })

    tool = acc.current_turn[:parts].last
    expect(tool[:output].size).to eq(Samagotchi::KernelLoop::DEFAULT_MAX_TOOL_OUTPUT_CHARS)
    expect(tool).to include(status: "ok", output_truncated: true)
  end

  it "tracks the pending question until it is answered or cancelled" do
    question = { id: "q1", question: "Which?", options: %w[A B], status: "pending" }
    feed({ type: :turn_started, prompt: "hi" }, { type: :question_requested, pending_question: question })
    expect(acc.current_turn[:pending_question]).to eq(question)

    feed({ type: :question_answered, id: "q1", answer: { selected: ["A"] } })
    expect(acc.current_turn[:pending_question]).to be_nil

    feed({ type: :question_requested, pending_question: question }, { type: :question_cancelled, id: "q1" })
    expect(acc.current_turn[:pending_question]).to be_nil
  end

  it "records steering input with its senders" do
    feed({ type: :turn_started, prompt: "hi" },
         { type: :input_merged, count: 1, origins: [{ client_id: "tui:1", enqueued_id: "e2" }] },
         { type: :pending_input_merged, iteration: 2, count: 1, content: "also this" })

    expect(acc.current_turn[:parts]).to eq([
      { kind: "input", iteration: 2, text: "also this", origins: [{ client_id: "tui:1", enqueued_id: "e2" }] }
    ])
  end

  it "keeps queued turns until they start or merge" do
    feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:1", prompt: "one" },
         { type: :turn_enqueued, enqueued_id: "e2", client_id: "tui:1", prompt: "two" },
         { type: :turn_enqueued, enqueued_id: "e3", client_id: "tui:1", prompt: "three" })
    expect(acc.queued.map { |q| q[:enqueued_id] }).to eq(%w[e1 e2 e3])

    feed({ type: :turn_started, prompt: "one", origin: { client_id: "web:1", enqueued_id: "e1" } },
         { type: :input_merged, count: 1, origins: [{ client_id: "tui:1", enqueued_id: "e2" }] })
    expect(acc.queued).to eq([{ enqueued_id: "e3", client_id: "tui:1", prompt: "three" }])
  end

  it "clears the turn when it completes, is canceled or fails" do
    %i[turn_completed turn_canceled turn_failed].each do |ending|
      feed({ type: :turn_started, prompt: "hi" }, { type: :generation_chunk, iteration: 1, content: "x" })
      expect(acc.current_turn).not_to be_nil
      feed({ type: ending })
      expect(acc.current_turn).to be_nil
    end
  end

  it "hands out copies that later events don't change" do
    feed({ type: :turn_started, prompt: "hi" }, { type: :generation_chunk, iteration: 1, content: "a" })
    snapshot = acc.current_turn
    feed({ type: :generation_chunk, iteration: 1, content: "b" })

    expect(snapshot[:parts].first[:text]).to eq("a")
    expect(acc.current_turn[:parts].first[:text]).to eq("ab")
  end
end
