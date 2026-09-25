# frozen_string_literal: true

require "json"
require "samagotchi/turn_tally"

RSpec.describe Samagotchi::TurnTally do
  subject(:tally) { described_class.new }

  def replay(tally, events)
    events.each do |e|
      key = [e["iteration"], e["call_index"]]
      if e["event"] == "started"
        tally.started(key: key, tool: e["tool"], params: e["params"])
      else
        tally.completed(key: key, tool: e["tool"], status: e["status"], params: e["params"])
      end
    end
    tally
  end

  # Shared contract: spec/shared/tally_matrix.json (the web's tally.test.js reads it too).
  matrix = JSON.parse(File.read(File.expand_path("shared/tally_matrix.json", __dir__)))["cases"]
  matrix.each do |c|
    it "matches the shared matrix: #{c["name"]}" do
      replay(tally, c["events"])
      expect(tally.text).to eq(c["text"])
      expect(tally.text(last: false)).to eq(c["text_no_last"])
    end
  end

  it "counts calls and resets" do
    3.times { |i| tally.started(key: [1, i], tool: "execute", params: "command=x") }
    expect(tally.count).to eq(3)
    tally.reset
    expect(tally.count).to eq(0)
    expect(tally.text).to be_nil
  end

  it "squashes whitespace in the last call's params" do
    3.times { |i| tally.started(key: [1, i], tool: "execute", params: "command=echo  a\nb") }
    expect(tally.text).to end_with("last: execute command=echo a b")
  end

  it "cuts to the width with an ellipsis" do
    3.times { |i| tally.started(key: [1, i], tool: "execute", params: "command=#{"x" * 80}") }
    text = tally.text(width: 40)
    expect(text.length).to eq(40)
    expect(text).to end_with("…")
    expect(tally.text(width: 400)).not_to end_with("…")
  end

  it "seeds from a joined turn's snapshot parts (string or symbol keys)" do
    parts = [
      { kind: "text", iteration: 1, text: "hi" },
      { kind: "tool", iteration: 1, call_index: 1, tool: "execute", params: "command=a", status: "error" },
      { "kind" => "tool", "iteration" => 2, "call_index" => 1, "tool" => "read_file", "params" => "path=b", "status" => "blocked" },
      { kind: "tool", iteration: 3, call_index: 1, tool: "execute", params: "command=c", status: "running" }
    ]
    tally.seed(parts)
    expect(tally.text).to eq("3 tool calls (1 failed) · execute ×2 · read_file ×1 · last: execute command=c")
    # The running call's completion lands on the seeded call.
    tally.completed(key: [3, 1], tool: "execute", status: "error")
    expect(tally.count).to eq(3)
    expect(tally.text(last: false)).to eq("3 tool calls (2 failed) · execute ×2 · read_file ×1")
  end
end
