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
