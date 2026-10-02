# frozen_string_literal: true

require "spec_helper"
require "samagotchi/turn_note"

RSpec.describe Samagotchi::TurnNote do
  it "is a tail system message with its own kind" do
    note = described_class.empty
    expect(note).to include(role: "system", kind: "turn_note")
    expect(note[:content]).to start_with("[SYSTEM: ").and end_with("]")
    expect(described_class.note?(note)).to be(true)
    expect(described_class.note?({ "role" => "system", "kind" => "turn_note" })).to be(true)
    expect(described_class.note?({ role: "system", content: "x" })).to be(false)
    expect(described_class.note?(nil)).to be(false)
  end

  describe ".empty" do
    it "carries a marker the UIs draw the notice from: the retries, and the empty steps when any" do
      steps = [{ role: "model", content: "<think>a</think>" }]
      expect(described_class.empty).to include(kind: "turn_note", empty_answer: { retries: 0 })
      expect(described_class.empty(retries: 2, steps: steps)).to include(empty_answer: { retries: 2, steps: steps })
      expect(described_class.empty(retries: 1)[:content]).to eq(described_class.empty[:content])
    end

    it "finds the marker with either key type, and nil on other messages" do
      expect(described_class.empty_answer(described_class.empty(retries: 1))).to eq({ retries: 1 })
      expect(described_class.empty_answer({ "role" => "system", "kind" => "turn_note", "empty_answer" => { "retries" => 2 } }))
        .to eq({ "retries" => 2 })
      expect(described_class.empty_answer(described_class.failed("x"))).to be_nil
      expect(described_class.empty_answer(nil)).to be_nil
    end

    it "words the notice the UIs show, with the retries when there were any" do
      expect(described_class.empty_answer_line(0)).to eq("no answer: the model returned nothing")
      expect(described_class.empty_answer_line(1)).to eq("no answer: the model returned nothing (after 1 retry)")
      expect(described_class.empty_answer_line("2")).to eq("no answer: the model returned nothing (after 2 retries)")
    end
  end

  it "names the failure on one line and says the message went unanswered" do
    note = described_class.failed("network error after 2 attempts\n(host main: ECONNREFUSED)")
    expect(note[:content]).to eq("[SYSTEM: the previous turn failed before any answer: network error after 2 attempts (host main: ECONNREFUSED). The user's last message was not answered.]")
  end

  it "says a restored prompt went back to the user" do
    expect(described_class.failed("HTTP 500", restored: true)[:content]).to end_with("The message went back to the user, who may send it again.]")
  end

  it "says how a cancel ended: nothing shown, or the answer cut off" do
    expect(described_class.cancelled(:ctrl_c, seconds: 6.4)[:content])
      .to eq("[SYSTEM: the previous turn was cancelled (ctrl-c) after 6s; no answer had been shown.]")
    expect(described_class.cancelled("user", seconds: 40, shown: true)[:content])
      .to eq("[SYSTEM: the previous turn was cancelled (user) after 40s; the answer above ends where it was cut off.]")
    expect(described_class.cancelled(nil)[:content]).to eq("[SYSTEM: the previous turn was cancelled; no answer had been shown.]")
  end

  it "names the hook that stopped the turn and why, as far as known" do
    expect(described_class.cancelled(:hook, seconds: 30, stopped_by: { by: "loop-guard", reason: "repeating  itself" })[:content])
      .to eq("[SYSTEM: the previous turn was cancelled (hook loop-guard: repeating itself) after 30s; no answer had been shown.]")
    expect(described_class.cancelled(:hook, stopped_by: { by: "check-in", reason: "" })[:content])
      .to start_with("[SYSTEM: the previous turn was cancelled (hook check-in);")
    expect(described_class.cancelled(:hook, stopped_by: nil)[:content]).to start_with("[SYSTEM: the previous turn was cancelled (hook);")
  end

  it "lists the background tasks a cancel left running, on one line and capped" do
    tasks = [{ id: "t1", command: "make   test\n  --verbose" }, { id: "t2", command: "x" * 80 }]
    expect(described_class.cancelled(:user, seconds: 212, running_tasks: tasks)[:content])
      .to eq("[SYSTEM: the previous turn was cancelled (user) after 212s; no answer had been shown. " \
             "Still running: task t1 (make test --verbose), task t2 (#{"x" * 59}…). " \
             "Continue with task_wait <id> or stop with task_stop <id>.]")

    many = (1..7).map { |i| { id: "t#{i}", command: "c#{i}" } }
    capped = described_class.cancelled(nil, running_tasks: many)[:content]
    expect(capped).to include("task t5 (c5), 2 more (task_list).")
    expect(capped).not_to include("t6")
  end

  it "marks both retry nudges, and says who cut a generation and why" do
    cut = described_class.cut_retry("loop-guard", "its thinking kept\nrepeating itself")

    expect(cut[:content]).to eq("[SYSTEM: your last reply was cut off by loop-guard: its thinking kept repeating itself. " \
                                "Don't start the same reasoning again; answer the user's last message now, briefly.]")
    expect([cut, described_class.empty_retry]).to all(satisfy { |note| described_class.retry_nudge?(note) && described_class.note?(note) })
    expect(described_class.retry_nudge?({ "retry_nudge" => true })).to be(true)
    expect(described_class.retry_nudge?(described_class.empty)).to be(false)
  end

  it "says an empty turn left the message unanswered" do
    expect(described_class.empty[:content]).to include("no visible answer").and include("still unanswered")
  end

  it "reads back a restored failure's summary from the tail, behind context notes" do
    context = { role: "system", content: "ctx", kind: "context_note" }
    user = { role: "user", content: "hi" }
    restored = described_class.failed("server error from host main: HTTP 500: boom", restored: true)
    expect(described_class.restored_failure([user, restored, context])).to eq("server error from host main: HTTP 500: boom")
    expect(described_class.restored_failure([restored.transform_keys(&:to_s)])).to eq("server error from host main: HTTP 500: boom")
    expect(described_class.restored_failure([restored, user])).to be_nil
    expect(described_class.restored_failure([described_class.failed("HTTP 500")])).to be_nil
    expect(described_class.restored_failure([described_class.empty])).to be_nil
    expect(described_class.restored_failure([])).to be_nil
  end
end
