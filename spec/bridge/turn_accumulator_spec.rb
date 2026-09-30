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

  it "keeps what an edit changed on its part, for a client that joins mid-turn" do
    diff = { text: "@@ -1 +1 @@\n-a\n+b", added: 1, removed: 1, truncated: false, new_file: false }
    feed({ type: :turn_started, prompt: "hi" },
         { type: :tool_call_started, iteration: 1, call_index: 1, tool: "edit", params: "path=x" },
         { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "edit", output: "Edited x", diff: diff,
           activity: { status: "ok" } })
    expect(acc.current_turn[:parts].last).to include(tool: "edit", diff: diff)
  end

  it "keeps a plugin tool's label on its part" do
    feed({ type: :turn_started, prompt: "hi" },
         { type: :tool_call_started, iteration: 1, call_index: 1, tool: "mcp_chrome_screenshot", label: "chrome: screenshot", params: "" })
    expect(acc.current_turn[:parts].last).to include(tool: "mcp_chrome_screenshot", label: "chrome: screenshot")
  end

  it "keeps a tool call's title on its part" do
    feed({ type: :turn_started, prompt: "hi" },
         { type: :tool_call_started, iteration: 1, call_index: 1, tool: "execute", params: 'command="cd /x && ls"', title: "ls" })
    expect(acc.current_turn[:parts].last).to include(tool: "execute", title: "ls")
  end

  it "keeps each of the turn's rows as a notice part holding its event, in stream order" do
    question = { id: "q1", question: "Which?", options: %w[A B], status: "pending" }
    feed({ type: :turn_started, prompt: "hi" },
         { type: :generation_chunk, iteration: 1, content: "Hm" },
         { type: :hook_notice, hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: :info },
         { type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1, finish_reason: "stop", thinking_chars: 40 },
         { type: :empty_answer_retry, iteration: 2, attempt: 1, of: 1, stopped_by: "loop-guard" },
         { type: :question_requested, pending_question: question },
         { type: :question_answered, id: "q1", answer: { selected: ["A"] } },
         { type: :question_cancelled, id: "q2", reason: "turn ended" })

    expect(acc.current_turn[:parts]).to eq([
      { kind: "text", iteration: 1, text: "Hm" },
      { kind: "notice", event: { type: "hook_notice", hook: "known_names.rb (bundle known-names)", text: "rejected execute", level: :info } },
      { kind: "notice", event: { type: "empty_answer_retry", iteration: 1, attempt: 1, of: 1 } },
      { kind: "notice", event: { type: "empty_answer_retry", iteration: 2, attempt: 1, of: 1, stopped_by: "loop-guard" } },
      { kind: "notice", event: { type: "question_requested", pending_question: question } },
      { kind: "notice", event: { type: "question_answered", id: "q1", answer: { selected: ["A"] } } },
      { kind: "notice", event: { type: "question_cancelled", id: "q2", reason: "turn ended" } }
    ])
    expect(JSON.parse(JSON.generate(acc.current_turn))["parts"][1]["event"]).to include("type" => "hook_notice", "level" => "info")
  end

  it "keeps no notice part outside a turn, and no provider retry (a status, not a row)" do
    feed({ type: :hook_notice, hook: "h", text: "between", level: :info, between_turns: true },
         { type: :turn_started, prompt: "hi" },
         { type: :generation_retrying, iteration: 1, attempt: 1, max_retries: 3, status: 503 })

    expect(acc.current_turn[:parts]).to eq([])
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

  it "records a plugin's steers after the user's input, the input keeping its senders" do
    origins = [{ client_id: "tui:1", enqueued_id: "e2" }]
    feed({ type: :turn_started, prompt: "hi" },
         { type: :input_merged, count: 1, origins: origins },
         { type: :pending_input_merged, iteration: 2, count: 1, content: "also this",
           steers: [{ source: "check-in", text: "how's it going?" }] })

    expect(acc.current_turn[:parts]).to eq([
      { kind: "input", iteration: 2, text: "also this", origins: origins },
      { kind: "steer", iteration: 2, source: "check-in", text: "how's it going?" }
    ])
    expect(described_class.messages_of(acc.current_turn).last(2)).to eq([
      { role: "user", content: "also this" },
      { role: "user", kind: "steer", source: "check-in", content: "how's it going?" }
    ])
  end

  it "a steer-only merge adds no input part and leaves the senders for the user's own merge" do
    origins = [{ client_id: "web:1", enqueued_id: "e3" }]
    feed({ type: :turn_started, prompt: "hi" },
         { type: :input_merged, count: 1, origins: origins },
         { type: :pending_input_merged, iteration: 2, count: 0, content: nil, steers: [{ source: "check-in", text: "nudge" }] },
         { type: :pending_input_merged, iteration: 3, count: 1, content: "late line" })

    expect(acc.current_turn[:parts]).to eq([
      { kind: "steer", iteration: 2, source: "check-in", text: "nudge" },
      { kind: "input", iteration: 3, text: "late line", origins: origins }
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

  it "keeps the last idle recap until the next turn starts" do
    expect(acc.recap).to be_nil
    feed({ type: :recap_ready, recap: "We talked about cats.", generation: 1 })
    expect(acc.recap).to eq("We talked about cats.")
    expect(acc.current_turn).to be_nil

    feed({ type: :turn_started, session_id: "s", prompt: "more" })
    expect(acc.recap).to be_nil
  end

  it "ignores a recap that lands after a turn started (it describes the chat before it)" do
    feed({ type: :turn_started, session_id: "s", prompt: "more" })
    feed({ type: :recap_ready, recap: "stale", generation: 1, covered: 4 })
    expect(acc.recap).to be_nil
  end

  it "keeps the pending continue offer until it is resolved, across turns in between" do
    context = { original_prompt: "the task", tool_trace: ["execute status=ok"], last_model_intent: "" }
    expect(acc.continue_offer).to be_nil

    feed({ type: :continue_offered, context: context, no_interrupt: false })
    expect(acc.continue_offer).to eq(context: context, no_interrupt: false)

    feed({ type: :continue_resolved, decision: "resume", client_id: "web:1" }, { type: :turn_started, continue: true })
    expect(acc.continue_offer).to be_nil

    feed({ type: :continue_offered, context: context, no_interrupt: true })
    offer = acc.continue_offer
    offer[:context][:original_prompt] << " changed"
    expect(acc.continue_offer[:context][:original_prompt]).to eq("the task")
  end

  it "hands out copies that later events don't change" do
    feed({ type: :turn_started, prompt: "hi" }, { type: :generation_chunk, iteration: 1, content: "a" })
    snapshot = acc.current_turn
    feed({ type: :generation_chunk, iteration: 1, content: "b" })

    expect(snapshot[:parts].first[:text]).to eq("a")
    expect(acc.current_turn[:parts].first[:text]).to eq("ab")
  end
end
