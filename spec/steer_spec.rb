# frozen_string_literal: true

require "samagotchi/steer"
require "samagotchi/pending_input_queue"
require "samagotchi/cancellation_controller"

RSpec.describe Samagotchi::Steer do
  describe ".merge" do
    it "joins the user lines into one message and follows it with each steer, in order" do
      merge = described_class.merge(["a", { text: " nudge ", source: "check-in" }, " b ", { "text" => "two", "source" => "x" }])

      expect(merge.messages).to eq([{ role: "user", kind: "input", content: "a\n\nb" },
                                    { role: "user", kind: "steer", source: "check-in", content: "nudge" },
                                    { role: "user", kind: "steer", source: "x", content: "two" }])
      expect(merge.event_fields).to eq(count: 2, content: "a\n\nb",
                                       steers: [{ source: "check-in", text: "nudge" }, { source: "x", text: "two" }])
    end

    it "is empty for nothing, blank lines or blank steers" do
      expect(described_class.merge(nil)).to be_empty
      expect(described_class.merge(["", "  ", { text: " ", source: "x" }])).to be_empty
    end

    it "keeps a plain merge's event fields as they were (no steers: key)" do
      expect(described_class.merge(["x"]).event_fields).to eq(count: 1, content: "x")
    end
  end

  describe ".drain" do
    it "passes at_answer only to a drain that takes it" do
      queue = Samagotchi::PendingInputQueue.new
      queue.push("line")
      seen = nil

      expect(described_class.drain(queue.method(:drain), at_answer: true)).to eq(["line"])
      expect(described_class.drain(->(at_answer: false) { seen = at_answer }, at_answer: true)).to be(true)
      expect(seen).to be(true)
      expect(described_class.drain(-> { raise "boom" }, at_answer: false)).to be_nil
    end
  end

  describe ".inject!" do
    let(:conversation) { [{ role: "user", content: "hi" }] }
    let(:events) { [] }
    let(:emit) { ->(event) { events << event } }

    def inject(pending_input, **options)
      described_class.inject!(conversation, pending_input, iteration: 2, emit: emit, cancel_controller: nil, **options)
    end

    it "appends the merge on the tail and emits :pending_input_merged" do
      expect(inject(-> { ["line", { text: "nudge", source: "check-in" }] })).to be(true)

      expect(conversation.drop(1)).to eq([{ role: "user", kind: "input", content: "line" },
                                          { role: "user", kind: "steer", source: "check-in", content: "nudge" }])
      expect(events).to eq([{ type: :pending_input_merged, iteration: 2, count: 1, content: "line",
                              steers: [{ source: "check-in", text: "nudge" }], answer: nil }])
    end

    it "does nothing without a drain, with nothing queued, or after a cancel (the input stays queued)" do
      cancelled = Samagotchi::CancellationController.new.tap(&:cancel!)
      drained = false

      expect(inject(nil)).to be(false)
      expect(inject(-> { [] })).to be(false)
      expect(described_class.inject!(conversation, -> { drained = true }, iteration: 1, emit: emit,
                                                                          cancel_controller: cancelled)).to be(false)
      expect(drained).to be(false)
      expect(conversation.size).to eq(1)
      expect(events).to be_empty
    end

    it "tells the drain it is the answer site when an answer is given, and names the answer" do
      seen = []
      drain = lambda do |at_answer: false|
        seen << at_answer
        ["line"]
      end

      inject(drain)
      inject(drain, answer: "A")

      expect(seen).to eq([false, true])
      expect(events.map { |event| event[:answer] }).to eq([nil, "A"])
    end

    it "builds a lazy answer only for a merge, and a blank one is none" do
      built = 0
      answer = lambda do
        built += 1
        "  \n "
      end

      inject(-> { [] }, answer: answer)
      expect(built).to eq(0)
      inject(-> { ["line"] }, answer: answer)
      expect(built).to eq(1)
      inject(-> { ["line"] }, answer: " ")

      expect(events.map { |event| event[:answer] }).to eq([nil, nil])
    end
  end

  it ".turn_prompt? is a prompt that started a turn: not a steer, not input merged into a running turn" do
    merged = described_class.merge(["also this"]).messages.first
    expect(described_class.input?(merged)).to be(true)
    expect(described_class.prompt?(merged)).to be(true)
    expect(described_class.turn_prompt?(merged)).to be(false)
    expect(described_class.turn_prompt?({ "role" => "user", "kind" => "input" })).to be(false)
    expect(described_class.turn_prompt?({ role: "user", content: "x" })).to be(true)
    expect(described_class.turn_prompt?(described_class.message(text: "x", source: "s"))).to be(false)
  end

  it ".prompt? is a user message that is not a steer, with either key kind" do
    expect(described_class.prompt?({ role: "user", content: "x" })).to be(true)
    expect(described_class.prompt?({ "role" => "user", "content" => "x" })).to be(true)
    expect(described_class.prompt?(described_class.message(text: "x", source: "s"))).to be(false)
    expect(described_class.prompt?({ "role" => "user", "kind" => "steer" })).to be(false)
    expect(described_class.prompt?({ role: "model", content: "x" })).to be(false)
  end
end
