# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/objectives_command"
require "samagotchi/worker_inbound"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::ObjectivesCommand do
  let(:tmpdir) { Dir.mktmpdir("objectives-command") }
  let(:locks) { [] }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:engine) do
    Struct.new(:session, :session_state_dir, :live_conversation, :announced) do
      def announce_objectives(session) = (self.announced = session)
    end.new(session, tmpdir)
  end
  let(:command) { described_class.new(engine: engine) }

  before { locks << Samagotchi::OwnerLock.acquire(session_dir, kind: "worker") }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def run(args) = command.run(args)
  def files = Samagotchi::SessionInbox.find_new_note_files(session_dir)
  def list = Samagotchi::Objectives.current(session.id, session.messages, state_dir: tmpdir)

  # A worker's pass: the real absorption, into a session the show then reads.
  def absorb
    fake = Object.new
    fake.define_singleton_method(:add_context_note) do |target, note|
      target.messages += [Samagotchi::ContextNote.message(**note)]
    end
    Samagotchi::WorkerInbound.new(session: session, state_dir: tmpdir, session_dir: session_dir, engine: fake,
                                  context_absorber: nil, wakes: nil, awaiting_continue: -> { false },
                                  stopped: -> { false }, queue_command: ->(*) {}).absorb_notes
  end

  it "says how to start when there is no list, and writes nothing" do
    output, status = run("")

    expect(status).to eq(:ok)
    expect(output).to include("no objectives").and include("/objectives set")
    expect(files).to be_empty
  end

  it "sets a list from | or from lines, and a done-when comes as the frame shows it" do
    output, status = run("set Two coffees, open the cart | Stops before checkout (done when: no order is placed)")

    expect(status).to eq(:ok)
    expect(output).to include("O1 Two coffees, open the cart", "O2 Stops before checkout (done when: no order is placed)",
                              described_class::BETWEEN_TURNS)
    expect(list.items.map(&:id)).to eq(%w[O1 O2])
    expect(list.items.last.done_when).to eq("no order is placed")

    run("set first\n  second   line\n\n")
    expect(list.items.map(&:text)).to eq(["first", "second line"])
    expect(list.items.map(&:id)).to eq(%w[O3 O4])
  end

  it "writes a note file a worker reads back as the objectives note" do
    run("set Aim")

    note = Samagotchi::SessionInbox.read_note(files.last)
    expect(note).to include(source: "objectives", text: "O1 Aim", header: "OBJECTIVES")
    expect(Samagotchi::Objectives.from_payload(note[:objectives])).to eq(list)
  end

  it "stacks a second edit on an unabsorbed first one" do
    run("set Aim")
    run("add Second")

    expect(list.items.map(&:text)).to eq(%w[Aim Second])
    expect(files.size).to eq(2)
  end

  it "edits the list the conversation holds once it is absorbed" do
    run("set Aim")
    absorb
    run("add Second")
    absorb
    run("done O1")
    absorb

    expect(list.items.map(&:status)).to eq(%w[done active])
    expect(run("").first).to include("O1 [done] Aim", "O2 Second").and(satisfy { |o| !o.include?(described_class::BETWEEN_TURNS) })
  end

  it "drops and marks done by any case and with commas, a dropped one still listed here" do
    run("set A | B | C")
    run("drop o1, O3")
    run("done o2")

    expect(list.items.map(&:status)).to eq(%w[dropped done dropped])
    expect(run("").first).to include("O1 [dropped] A", "O2 [done] B")
  end

  it "leaves a dropped item dropped: done refuses it, undo brings it back" do
    run("set A | B")
    run("drop O1")

    output, status = run("done O1 O2")
    expect(status).to eq(:error)
    expect(output).to include("O1 is dropped", "#{described_class::NAME} undo O1")
    expect(list.items.map(&:status)).to eq(%w[dropped active])

    run("undo O1")
    expect(list.items.map(&:status)).to eq(%w[active active])
  end

  it "undoes a mistaken done" do
    run("set A")
    run("done O1")
    run("undo o1")

    expect(list.items.first.status).to eq("active")
  end

  describe "the text it takes" do
    def entries(args)
      run("set #{args}")
      list.items.map { |item| [item.text, item.done_when] }
    end

    it "refuses a done-when with no text, alone or among others" do
      ["(done when: y)", "A | (done when: y)"].each do |args|
        expect(run("set #{args}")).to eq([described_class::USAGE, :error])
      end
      expect(files).to be_empty
    end

    it "takes an empty done-when as none" do
      expect(entries("A (done when: )")).to eq([["A", nil]])
    end

    it "takes the last of two done-when groups, the other stays text" do
      expect(entries("A (done when: x) (done when: y)")).to eq([["A (done when: x)", "y"]])
    end

    it "keeps parentheses inside a done-when" do
      expect(entries("A (done when: no (real) order)")).to eq([["A", "no (real) order"]])
    end

    it "doesn't let a text pass for a status: a leading marker goes" do
      run("add [done] fake")
      run("add [DROPPED] [done]  other")

      expect(list.items.map(&:text)).to eq(%w[fake other])
      expect(list.items.map(&:status)).to eq(%w[active active])
      expect(list.text).to eq("O1 fake\nO2 other")
    end

    it "refuses a text that is only a marker" do
      expect(run("add [done]")).to eq([described_class::USAGE, :error])
    end

    it "collapses Unicode line separators and spaces into one space" do
      expect(entries("one\u2028two\u2029three\u0085four\u00a0five").first.first).to eq("one two three four five")
      expect(list.text).not_to match(/[\u2028\u2029\u0085]/)
    end
  end

  it "refuses an id it doesn't have, writing nothing" do
    run("set A")
    before = files.size

    output, status = run("done O1 O9")

    expect(status).to eq(:error)
    expect(output).to include("no objective O9")
    expect(files.size).to eq(before)
  end

  it "writes nothing for a change that changes nothing" do
    run("set A")
    run("done O1")
    before = files.size

    output, status = run("done O1")

    expect(status).to eq(:ok)
    expect(output).to include("(no change)")
    expect(files.size).to eq(before)
  end

  it "answers the usage for a line that isn't one" do
    ["nonsense", "set", "set  | ", "add", "done", "drop", "undo"].each do |args|
      output, status = run(args)

      expect(status).to eq(:error)
      expect(output).to eq(described_class::USAGE)
    end
    expect(files).to be_empty
  end

  it "refuses an edit in a session a chi REPL owns, with the note's own reason; a show still answers" do
    locks.pop.release
    locks << Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")

    output, status = run("set A")

    expect(status).to eq(:error)
    expect(output).to eq("refused: #{Samagotchi::NoteDelivery::REPL_REFUSAL}")
    expect(files).to be_empty
    expect(run("").last).to eq(:ok)
  end

  it "says so for a list over the note limit, writing nothing" do
    output, status = run("set #{"x" * (Samagotchi::SessionInbox::NOTE_MAX_BYTES + 1)}")

    expect(status).to eq(:error)
    expect(output).to include("16 KiB")
    expect(files).to be_empty
  end

  it "answers plainly with no session yet" do
    engine.session = nil

    expect(run("set A")).to eq(["no session yet", :error])
  end

  describe "moves" do
    before do
      list = Samagotchi::Objectives::List.new.set([{ text: "Two coffees" }, { text: "Stops before checkout" }])
      session.messages = [
        Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: Samagotchi::Objectives::SOURCE,
                                        header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload),
        { role: "model", content: "", tool_calls: [{ id: "a", name: "objectives",
                                                     arguments: { action: "move", id: "O2", note: "Closed", evidence: "spec" } }] },
        { role: "tool_response", content: "[objectives]\nRecorded a move on O2.", tool_call_id: "a", tool_ids: ["t1"] }
      ]
    end

    it "shows an objective's latest move under it, and none where there is none" do
      expect(run("")).to eq(["objectives:\n  O1 Two coffees\n  O2 Stops before checkout\n    last move: Closed (evidence: spec)", :ok])
    end

    it "shows a move of the running turn, which session.messages doesn't hold yet" do
      engine.live_conversation = [
        { role: "model", content: "", tool_calls: [{ id: "b", name: "objectives", arguments: { id: "O1", note: "Mid-turn" } }] },
        { role: "tool_response", content: "[objectives]\nRecorded a move on O1.", tool_call_id: "b", tool_ids: ["t2"] }
      ]

      expect(run("").first).to include("O1 Two coffees\n    last move: Mid-turn",
                                       "last move: Closed (evidence: spec)")
    end

    it "sends no move in an edit's list" do
      run("done O2")

      note = Samagotchi::SessionInbox.read_note(files.first)
      expect(note[:text]).to eq("O1 Two coffees\nO2 [done] Stops before checkout")
    end
  end
end
