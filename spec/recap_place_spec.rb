# frozen_string_literal: true

require "samagotchi/recap_place"

# A saved recap's stamp: the id of the last turn opening it covers.
RSpec.describe Samagotchi::RecapPlace do
  def prompt(text, id) = { role: "user", content: text, turn_id: id }
  def answer(text) = { role: "model", content: text }

  it "names the last opening the recap covers, not a later one" do
    messages = [{ role: "system", content: "sys" }, prompt("one", "t1"), answer("a"), prompt("two", "t2"), answer("b"),
                prompt("three", "t3"), answer("c")]
    expect(described_class.opening_id(messages, 5)).to eq("t2")
    expect(described_class.opening_id(messages, 7)).to eq("t3")
  end

  it "is nil with no opening covered, or one with no id (a line an older chi wrote)" do
    expect(described_class.opening_id([{ role: "system", content: "sys" }, prompt("one", "t1")], 1)).to be_nil
    expect(described_class.opening_id([{ role: "user", content: "old" }, answer("a")], 2)).to be_nil
    expect(described_class.opening_id([], 0)).to be_nil
  end

  it "takes a wake note's turn_id and a /continue no reason line's opening_id, with string keys too" do
    wake = { "role" => "system", "kind" => "note", "turn_start" => true, "turn_id" => "wake-1", "content" => "done" }
    expect(described_class.opening_id([prompt("one", "t1"), answer("a"), wake, answer("b")], 4)).to eq("wake-1")
    # TurnFlow#abort_continue!'s line: a user message with its own id, no turn_id.
    reason = { role: "user", content: "Not continued: too slow", opening_id: "op-1" }
    expect(described_class.opening_id([prompt("one", "t1"), answer("a"), reason], 3)).to eq("op-1")
  end

  it "skips a !cmd's record, which opens no turn" do
    expect(described_class.opening_id([prompt("one", "t1"), answer("a"), { role: "user", content: "!(ls)\nfile" }], 3)).to eq("t1")
  end

  it "reads every message when covered runs past the end" do
    expect(described_class.opening_id([prompt("one", "t1"), answer("a")], 40)).to eq("t1")
  end
end
