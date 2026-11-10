# frozen_string_literal: true

require "json"
require "samagotchi/bridge/turn_ranges"
require "samagotchi/context_note"
require "samagotchi/turn_note"
require "samagotchi/web/message_display"
require "support/turn_drawing_scenarios"

# Bridge::TurnRanges: the turns read back from a session's messages. Its
# ranges are the Engine's kept_from...kept_to (every TurnDrawingScenarios
# end), and its record pairing (by id, else by place) is what a made line's
# end names (record_id). The cases' fixture, spec/shared/turn_ranges.json
# (written with UPDATE_TURN_RANGES=1), holds each case's messages, records,
# display items as the show stamps them (MessageDisplay), each turn's
# drawing's end and the expected turns; timing.test.js reads it too (the
# page groups by the stamps).
RSpec.describe Samagotchi::Bridge::TurnRanges do
  fixture_path = File.expand_path("../shared/turn_ranges.json", __dir__)
  head = { role: "system", content: "You are chi." }
  at = TurnDrawingScenarios::AT
  user = ->(text, id = nil, **extra) { { role: "user", content: text, at: at, **(id ? { turn_id: id } : {}), **extra } }
  model = ->(text) { { role: "model", content: text } }
  reminder = { role: "system", content: "[SYSTEM: REMINDERS DUE 2026-11-08 10:00 local]\n- tea: brew", at: at }
  # A note's header shows its time in local time: built in the scenarios' zone.
  note = TurnDrawingScenarios.in_zone { Samagotchi::ContextNote.message(note_id: "n1", text: "a note", source: "chi_note", created_at: "2026-11-08T09:00:00Z") }
  wake = TurnDrawingScenarios.in_zone do
    Samagotchi::ContextNote.message(note_id: "n2", text: "pr-7 changed", source: "context", created_at: "2026-11-08T09:00:00Z")
                           .merge(turn_start: true, turn_id: "t2")
  end
  record = ->(id, status = "completed") { { "id" => id, "status" => status, "duration_ms" => 1000 } }
  turn = ->(from, to, id, opening, record_id, turn_id: id) { { from: from, to: to, id: id, turn_id: turn_id, opening: opening, record_id: record_id } }

  cases = {
    by_id: {
      description: "Turn ids pair with their records by id, whatever the records' order.",
      messages: [head, user.call("one", "t1"), model.call("a"), user.call("two", "t2"), model.call("b")],
      records: [record.call("t2"), record.call("other"), record.call("t1")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), turn.call(3, 5, "t2", 3, "t2")]
    },
    by_place: {
      description: "Turns saved before turn ids pair by their place among the openings.",
      messages: [head, user.call("one"), model.call("a"), user.call("two"), model.call("b")],
      records: [record.call("r1"), record.call("r2")],
      turns: [{ from: 1, to: 3, opening: 1, record_id: "r1" }, { from: 3, to: 5, opening: 3, record_id: "r2" }]
    },
    reminders_before_prompt: {
      description: "Reminders that went into a prompt's turn start its range.",
      messages: [head, user.call("one", "t1"), model.call("a"), reminder, user.call("two", "t2"), model.call("b")],
      records: [record.call("t1"), record.call("t2")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), turn.call(3, 6, "t2", 4, "t2")]
    },
    reminder_turn: {
      description: "A reminder turn after a prompt's: its own range, no opening, no record by place.",
      messages: [head, user.call("one", "t1"), model.call("a"), reminder, model.call("tea")],
      records: [record.call("t1"), record.call("t-reminder")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), { from: 3, to: 5, opening: nil, record_id: nil }]
    },
    wake_note: {
      description: "A context wake's note opens its turn from outside the range.",
      messages: [head, user.call("one", "t1"), model.call("a"), wake, model.call("woke")],
      records: [record.call("t1"), record.call("t2")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), turn.call(4, 5, "t2", 3, "t2")]
    },
    wake_report: {
      description: "A delegate report's wake turn opens with the report (turn_start input).",
      messages: [head, user.call("one", "t1"), model.call("a"),
                 { role: "user", kind: "input", source: "delegate_report", content: "[report] done", at: at, turn_start: true, turn_id: "t2" },
                 model.call("noted")],
      records: [record.call("t1"), record.call("t2")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), turn.call(3, 5, "t2", 3, "t2")]
    },
    shell_between: {
      description: "A `!cmd`'s record between turns is no turn's and counts for no place.",
      messages: [head, user.call("one"), model.call("a"), user.call("!(ls)\na.txt"), user.call("two"), model.call("b")],
      records: [record.call("r1"), record.call("r2")],
      turns: [{ from: 1, to: 3, opening: 1, record_id: "r1" }, { from: 4, to: 6, opening: 4, record_id: "r2" }]
    },
    notes_between: {
      description: "A context note after a turn and before the next is outside both.",
      messages: [head, user.call("one", "t1"), model.call("a"), note, user.call("two", "t2"), model.call("b")],
      records: [record.call("t1"), record.call("t2")],
      turns: [turn.call(1, 3, "t1", 1, "t1"), turn.call(4, 6, "t2", 4, "t2")]
    },
    duplicate_id: {
      description: "A later range repeating a turn id (a hand-edited file) gets <id>~<from>.",
      messages: [head, user.call("one", "t1"), model.call("a"), Samagotchi::TurnNote.failed_after("boom", 1),
                 user.call("one", "t1"), model.call("b")],
      records: [record.call("t1", "failed")],
      # Whose record a repeated id's later range has can't be told: none.
      turns: [turn.call(1, 4, "t1", 1, "t1"), turn.call(4, 6, "t1~4", 4, nil, turn_id: "t1")]
    },
    restored_failure: {
      description: "A failure that handed its prompt back is a range of its note alone: not the turn before's, and its " \
                   "record (no opening) takes no place among the openings.",
      messages: [head, user.call("one"), model.call("a"), Samagotchi::TurnNote.failed("down", restored: true),
                 user.call("two"), model.call("b")],
      records: [record.call("r1"), record.call("rF", "failed").merge("failure" => { "summary" => "down" }), record.call("r2")],
      turns: [{ from: 1, to: 3, opening: 1, record_id: "r1" }, { from: 3, to: 4, opening: nil, record_id: nil },
              { from: 4, to: 6, opening: 4, record_id: "r2" }]
    }
  }

  display = Class.new do
    include Samagotchi::Web::MessageDisplay

    public :messages_for_display
  end.new

  # The case as the fixture has it: JSON's string keys, the page's items.
  def self.wire(value) = JSON.parse(JSON.generate(value))

  # The items as the show stamps them (MessageDisplay, a line per range),
  # which each range holds (what turnGroups' groups must hold too,
  # timing.test.js), and each range's drawing as a made line's end names it
  # (its own turn id, its record's id).
  def self.stamped(display, messages, records)
    ranges = described_class.of(messages)
    lines = ranges.map do |range|
      Samagotchi::Bridge::TurnDrawings::Line.new(v: 1, turn_id: range.id, kind: "completed", from: range.from, to: range.to,
                                                 from_digest: "", to_digest: "", drawing: {}, end: {})
    end
    items = display.messages_for_display(messages, markdown: false, drawings: lines)
    drawings = ranges.zip(described_class.records(ranges, records)).to_h do |range, record|
      ending = { type: "turn_completed", turn_id: (range.id if range.own_id?), record_id: record&.fetch("id") }.compact
      [range.id, { events: [], end: ending }]
    end
    [items, ranges.map { |range| items.each_index.select { |i| items[i][:drawn] == range.id } }, drawings]
  end

  built = cases.to_h do |name, spec|
    items, held, drawings = stamped(display, spec[:messages], spec[:records])
    turns = spec[:turns].each_with_index.map { |turn, k| turn.merge(items: held[k]) }
    [name.to_s, wire(spec.merge(turns: turns, items: items, drawings: drawings))]
  end

  describe ".of and .records on the shared cases (spec/shared/turn_ranges.json)" do
    built.each do |name, spec|
      it "#{name}: #{spec["description"]}" do
        ranges = described_class.of(spec["messages"])
        records = described_class.records(ranges, spec["records"])
        # A case's turn names its ids when it has them (a made-up id is
        # checked on its own, below).
        got = ranges.zip(records, spec["turns"]).map do |range, rec, want|
          ids = want&.key?("id") ? { "id" => range.id, "turn_id" => range.turn_id } : {}
          { "from" => range.from, "to" => range.to, "opening" => range.opening, "record_id" => rec&.fetch("id"), **ids }
        end
        expect(got).to eq(spec["turns"].map { |t| t.except("items") })
      end
    end

    it "matches the fixture (UPDATE_TURN_RANGES=1 writes it)" do
      if ENV["UPDATE_TURN_RANGES"]
        File.write(fixture_path, "#{JSON.pretty_generate(built)}\n")
      else
        expect(File.exist?(fixture_path) ? JSON.parse(File.read(fixture_path)) : nil).to eq(built),
                                                                                         "run with UPDATE_TURN_RANGES=1 to write #{fixture_path}"
      end
    end
  end

  describe "the Engine's ranges (TurnDrawingScenarios)" do
    TurnDrawingScenarios.all.each do |scenario|
      it "cuts #{scenario[:name]} at each end event's kept_from...kept_to" do
        ends = scenario[:ends].dup
        scenario[:events].select { |event| Samagotchi::Events::TURN_END.include?(event[:type]) }.each do |event|
          messages = ends.shift
          last = described_class.of(messages).last
          expect([last.from, last.to]).to eq([event[:kept_from], event[:kept_to]])
          expect(last.turn_id).to eq(messages[last.opening][:turn_id]) if last.opening
        end
      end
    end
  end

  it "makes up a display id for a turn with no turn id, from its first message" do
    ranges = described_class.of([head, user.call("one"), model.call("a")])
    expect(ranges.first.id).to match(/\Am1-[0-9a-f]{8}\z/)
    expect(ranges.first.own_id?).to be(false)
  end

  it "keeps a lone answer before any prompt as a range of its own" do
    expect(described_class.of([head, model.call("hi")]).map { |r| [r.from, r.to, r.opening] }).to eq([[1, 2, nil]])
  end
end
