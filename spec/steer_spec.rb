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

    it "saves a Line's source on its input message, and a user Line like a String" do
      line = described_class::Line
      merge = described_class.merge([line.new(text: "a", source: "chi_send"), line.new(text: " b ", source: "chi_send")])
      expect(merge.messages).to eq([{ role: "user", kind: "input", source: "chi_send", content: "a\n\nb" }])

      user = described_class.merge([line.new(text: "a", source: nil), "b"])
      expect(user.messages).to eq(described_class.merge(%w[a b]).messages)
    end

    it "saves one input message per run of the same sender; the event still joins every line" do
      line = described_class::Line
      merge = described_class.merge([line.new(text: "a", source: nil), line.new(text: "b", source: "chi_send"),
                                     line.new(text: "c", source: "chi_send"), "d", { text: "n", source: "check-in" }])

      expect(merge.messages).to eq([{ role: "user", kind: "input", content: "a" },
                                    { role: "user", kind: "input", source: "chi_send", content: "b\n\nc" },
                                    { role: "user", kind: "input", content: "d" },
                                    { role: "user", kind: "steer", source: "check-in", content: "n" }])
      expect(merge.event_fields).to eq(count: 4, content: "a\n\nb\n\nc\n\nd",
                                       steers: [{ source: "check-in", text: "n" }])
    end

    it "puts a Line's mark on its input message: a wake turn's report starts its turn" do
      mark = { turn_start: true, turn_id: "T9" }
      line = described_class::Line.new(text: "report", source: "delegate_report", mark: mark)
      expect(line).not_to eq(described_class::Line.new(text: "report", source: "delegate_report"))
      message = described_class.merge([line]).messages.first
      expect(message).to eq(role: "user", kind: "input", source: "delegate_report", turn_start: true, turn_id: "T9", content: "report")
      expect(described_class.turn_prompt?(message)).to be(true)
      expect(described_class.turn_prompt?(message.except(:turn_start))).to be(false)
    end

    it "lists the delegate reports apart in the merge event, one per report" do
      reports = ["session: c1\nstatus: answered\n---\n3", "session: c2\nstatus: failed\nboom"]
      merge = described_class.merge(["hi", *reports.map { |r| described_class::Line.new(text: r, source: "delegate_report") }])
      expect(merge.event_fields).to include(count: 3, reports: reports)
      expect(described_class.merge(["hi"]).event_fields).not_to have_key(:reports)
    end

    it "skips blank Lines" do
      expect(described_class.merge([described_class::Line.new(text: " ", source: "chi_send")])).to be_empty
    end
  end

  describe ".source_for_client" do
    it "maps a worker input's client id to the saved source (nil = the user)" do
      expected = { nil => nil, "web:abc" => nil, "tui:123" => nil, "cli:send" => "chi_send",
                   "delegate:abcd1234" => "parent_agent", "plugin" => "plugin_send",
                   "child:abcd1234" => "delegate_report", "context:pr-1" => "automatic:context:pr-1",
                   "system:reminder" => "automatic:system:reminder", "cli:answer" => "automatic:cli:answer",
                   "other" => "automatic:other", "" => "automatic:" }
      expect(expected.keys.to_h { |id| [id, described_class.source_for_client(id)] }).to eq(expected)
      expect(described_class.cuts?("delegate_report")).to be(false)
    end

    it "never takes a line from a client it doesn't know for the user's: it doesn't cut, its header names the client" do
      source = described_class.source_for_client("ci:nightly")
      expect(described_class.cuts?(source)).to be(false)
      expect(described_class.wire_text({ kind: "input", source: source, content: "rebase done" }))
        .to eq("[Automatic input from ci:nightly, sent mid-task; not your user's message. " \
               "If it asks for nothing, carry on with the task.]\nrebase done")
      expect(described_class.header({ kind: "input", source: described_class.source_for_client("") }))
        .to start_with("[Automatic input from an unnamed client, sent mid-task;")
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

  describe ".header / .wire_text" do
    tail = "mid-task. Follow it; if it asks for nothing, carry on with the task.]"

    it "names the sender of a steer or merged input" do
      {
        { kind: "input" } => "[Steer from the user, #{tail}",
        { kind: "input", source: "user" } => "[Steer from the user, #{tail}",
        { kind: "input", source: "chi_send" } => "[Steer sent with chi send, #{tail}",
        { kind: "input", source: "parent_agent" } => "[Steer from the parent agent that started this session, #{tail}",
        { kind: "input", source: "plugin_send" } => "[Steer sent by a plugin, #{tail}",
        { kind: "input", source: "mystery" } => "[Steer from the user, #{tail}",
        { kind: "steer", source: "user" } => "[Steer from the user, #{tail}",
        { kind: "steer", source: "parent_agent" } => "[Steer from the parent agent that started this session, #{tail}",
        { "kind" => "steer", "source" => "check-in" } => "[Steer from the check-in plugin, #{tail}"
      }.each { |message, header| expect(described_class.header(message)).to eq(header), message.inspect }
    end

    it "takes a source's own whole header line from HEADERS, for input and steers alike" do
      stub_const("Samagotchi::Steer::HEADERS", { "robot" => "[Robot says]" })
      expect(described_class.header({ kind: "input", source: "robot" })).to eq("[Robot says]")
      expect(described_class.wire_text({ kind: "steer", source: "robot", content: "x" })).to eq("[Robot says]\nx")
      expect(described_class.header({ kind: "input", source: "chi_send" })).to eq("[Steer sent with chi send, #{tail}")
    end

    it "gives a delegate report its own header: chi's news for the user, not a steer to follow" do
      header = described_class.header({ kind: "input", source: "delegate_report" })
      expect(header).to start_with("[Delegate report, delivered by chi when your delegate session ended its turn; " \
                                   "not your user's message. Tell your user what it found or what went wrong")
      expect(header).to end_with("include it in your reply and finish the task. Don't call delegate_result for it; " \
                                 "to retry or redirect that child, use delegate with its session:.]")
      expect(header).not_to include("Follow it")
    end

    it "has none for a prompt, a model message or a note" do
      expect(described_class.header({ role: "user", content: "x" })).to be_nil
      expect(described_class.header({ role: "system", kind: "note", content: "x" })).to be_nil
    end

    it "puts the header on its own line before the text" do
      expect(described_class.wire_text({ kind: "input", content: "a" })).to eq("[Steer from the user, #{tail}\na")
      expect(described_class.wire_text({ kind: "input", content: "a" }, "b")).to eq("[Steer from the user, #{tail}\nb")
      expect(described_class.wire_text({ role: "user", content: "a" })).to eq("a")
    end
  end

  it ".person? is a steer from the user or the parent agent, with either key kind" do
    expect(described_class.person?({ kind: "steer", source: "user" })).to be(true)
    expect(described_class.person?({ "kind" => "steer", "source" => "parent_agent" })).to be(true)
    expect(described_class.person?({ "kind" => "steer", "source" => "check-in" })).to be(false)
    expect(described_class.person?({ kind: "steer", source: "" })).to be(false)
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

  it ".turn_prompt? is also a context wake turn's note (system, turn_start), not any other note" do
    note = { role: "system", kind: "note", content: "[CONTEXT NOTE …]" }
    expect(described_class.turn_prompt?(note.merge(turn_start: true, turn_id: "t1"))).to be(true)
    expect(described_class.turn_prompt?({ "role" => "system", "kind" => "note", "turn_start" => true })).to be(true)
    expect(described_class.turn_prompt?(note)).to be(false)
    expect(described_class.turn_prompt?({ role: "system", content: "sys" })).to be(false)
  end

  it ".prompt? is a user message that is not a steer, with either key kind" do
    expect(described_class.prompt?({ role: "user", content: "x" })).to be(true)
    expect(described_class.prompt?({ "role" => "user", "content" => "x" })).to be(true)
    expect(described_class.prompt?(described_class.message(text: "x", source: "s"))).to be(false)
    expect(described_class.prompt?({ "role" => "user", "kind" => "steer" })).to be(false)
    expect(described_class.prompt?({ role: "model", content: "x" })).to be(false)
  end
end
