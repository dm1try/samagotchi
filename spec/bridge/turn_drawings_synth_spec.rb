# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/bridge/card_store"
require "samagotchi/bridge/turn_accumulator"
require "samagotchi/bridge/turn_drawings"
require "samagotchi/bridge/turn_drawings/synth"
require "samagotchi/bridge/turn_ranges"
require "samagotchi/events"
require "samagotchi/web/message_display"
require "samagotchi/web/session_show"
require "support/turn_drawing_scenarios"

# Bridge::TurnDrawings::Synth: a turn's drawing made from its saved
# messages, its records and CardStore's entries, for every shared scenario
# the same as the line live wrote, but for what Synth::LOSSES declares.
RSpec.describe Samagotchi::Bridge::TurnDrawings::Synth do
  drawings = Samagotchi::Bridge::TurnDrawings

  # The scenario as a session keeps it: its real lines (a live
  # accumulator), CardStore's entries, and the timing records SessionMetrics
  # would have saved (a turn record per end, a tool record per call).
  def kept(scenario)
    dir = Dir.mktmpdir
    ends = scenario[:ends].dup
    messages = nil
    store = Samagotchi::Bridge::TurnDrawings.new(path: File.join(dir, "d.jsonl"), messages: -> { messages })
    accumulator = Samagotchi::Bridge::TurnAccumulator.new(on_turn_end: store.method(:append))
    cards = Samagotchi::Bridge::CardStore.new(messages: -> { messages })
    turns = []
    tools = []
    turn_id = nil
    scenario[:events].each do |event|
      messages = ends.shift if Samagotchi::Events::TURN_END.include?(event[:type])
      accumulator.call(event)
      cards.call(event)
      turn_id = event[:turn_id] if event[:type] == :turn_started
      if event[:type] == :tool_call_completed
        tools << { "id" => "#{turn_id}:#{event[:call_index]}", "turn_id" => turn_id, "iteration" => event[:iteration],
                   "call_index" => event[:call_index], "tool" => event[:tool], "status" => event.dig(:activity, :status),
                   "duration_ms" => event[:duration_ms] }
      end
      turns << turn_record(event) if Samagotchi::Events::TURN_END.include?(event[:type])
    end
    lines = Samagotchi::Bridge::TurnDrawings.parse(File.read(File.join(dir, "d.jsonl")))
    { lines: lines, entries: JSON.parse(JSON.generate(cards.list(messages: scenario[:messages]))), turns: turns, tools: tools }
  ensure
    FileUtils.rm_rf(dir)
  end

  def turn_record(event)
    status = Samagotchi::Bridge::TurnDrawings::KINDS.fetch(event[:type].to_s)
    record = { "id" => event[:turn_id], "status" => status, "duration_ms" => event[:duration_ms] }
    record["cancellation_reason"] = event[:cancellation_reason] if event[:cancellation_reason]
    if status == "failed"
      record["failure"] = { "summary" => event[:summary], "kept_steps" => event[:kept_steps] }.compact
    end
    record
  end

  # A line as both sides can have it: Synth::LOSSES taken out of both.
  # +unopened+: a turn with no opening (its id and record are lost).
  def comparable(line, unopened: false, woken: false)
    out = JSON.parse(JSON.generate(line.to_h))
    out["drawing"].delete("at") if woken
    out["drawing"].delete("origin")
    out["end"].delete("record_id")
    %w[message error_class].each { |key| out["end"].delete(key) } if out["end"]["summary"]
    if unopened
      out.delete("turn_id")
      out["drawing"].delete("turn_id")
      %w[turn_id duration_ms].each { |key| out["end"].delete(key) }
    end
    parts = out["drawing"]["parts"]
    redone = parts.filter_map { |p| p.dig("event", "iteration") if %w[empty_answer_retry steer_cut].include?(p.dig("event", "type")) }
    visible = parts.select { |p| %w[text tool].include?(p["kind"]) }.map { |p| p["iteration"] }
    parts.each do |part|
      part.delete("origins") if part["kind"] == "input"
      part["reminders"] = part["reminders"].map { |r| r.slice("name") } if part["kind"] == "reminder"
    end
    # An empty step's thinking (asked again, or the empty answer's) is kept
    # only on the empty answer's marker.
    parts.reject! { |p| p["kind"] == "thinking" && (redone.include?(p["iteration"]) || !visible.include?(p["iteration"])) }
    out
  end

  # chi web's show of the scenario's session were its turns drawn from
  # these lines (MessageDisplay's stamps, SessionShow's unfold).
  def show_of(messages, lines)
    host = Class.new do
      include Samagotchi::Web::MessageDisplay
      include Samagotchi::Web::SessionShow

      public :messages_for_display, :turn_drawings_field
    end.new
    items = host.messages_for_display(messages, markdown: false, drawings: lines)
    JSON.parse(JSON.generate({ messages: items, **host.turn_drawings_field(lines, items) }))
  end

  # The scenario's synthesized show (its fixture's `synth`, which the node
  # parity test draws against the live turn): every valid line's range
  # synthesized instead.
  describe "the shared scenarios' synthesized show (spec/shared/turn_drawings)" do
    TurnDrawingScenarios.all.each do |scenario|
      it "writes #{scenario[:name]}'s synth show" do
        kept = kept(scenario)
        ranges = Samagotchi::Bridge::TurnRanges.of(scenario[:messages])
        records = Samagotchi::Bridge::TurnRanges.records(ranges, kept[:turns])
        lines = drawings.valid(kept[:lines], scenario[:messages]).map do |real|
          index = ranges.index { |r| r.from == real.from && r.to == real.to }
          described_class.line(scenario[:messages], ranges[index], record: records[index], tools: kept[:tools], entries: kept[:entries])
        end
        shown = show_of(scenario[:messages], lines)
        file = TurnDrawingScenarios.path(scenario[:name])
        saved = JSON.parse(File.read(file))
        if ENV["UPDATE_TURN_DRAWINGS"]
          File.write(file, "#{JSON.pretty_generate(saved.merge("synth" => shown))}\n")
        else
          expect(saved["synth"]).to eq(shown), "run with UPDATE_TURN_DRAWINGS=1 to write #{file}"
        end
        expect(shown["turn_drawings"]).not_to be_empty
      end
    end
  end

  TurnDrawingScenarios.all.each do |scenario|
    it "draws #{scenario[:name]} from its messages as live drew it, but for LOSSES" do
      kept = kept(scenario)
      valid = drawings.valid(kept[:lines], scenario[:messages])
      ranges = Samagotchi::Bridge::TurnRanges.of(scenario[:messages])
      records = Samagotchi::Bridge::TurnRanges.records(ranges, kept[:turns])
      valid.each do |real|
        index = ranges.index { |r| r.from == real.from && r.to == real.to }
        expect(index).not_to be_nil, "no range #{real.from}...#{real.to} in #{ranges.inspect}"
        synth = described_class.line(scenario[:messages], ranges[index], record: records[index], tools: kept[:tools],
                                                                          entries: kept[:entries])
        # A range whose id repeats an earlier one's (…~N) has none of the turn's ids or records either.
        unopened = ranges[index].opening.nil? || !ranges[index].own_id?
        woken = !unopened && ranges[index].opening < ranges[index].from
        expect(comparable(synth, unopened: unopened, woken: woken)).to eq(comparable(real, unopened: unopened, woken: woken))
        expect(synth.end["record_id"]).to eq(real.turn_id) unless unopened
      end
    end
  end

  # The same turns saved before turn ids: no id on the openings, the
  # records paired by place, no CardStore entry of theirs (those name ids).
  describe "a session saved before turn ids" do
    # Not: a turn with CardStore rows (they name its id), a rollback (its
    # record by place is the rolled-back turn's), a wake (newer than ids).
    rows = %i[card hook_notice empty_answer_retry steer_cut llm_context_edited question_requested]
    TurnDrawingScenarios.all.each do |scenario|
      next if scenario[:events].any? { |e| rows.include?(e[:type]) } || %w[rollback_rerun wake_turn].include?(scenario[:name])

      it "draws #{scenario[:name]} with a made-up id and its record by place" do
        kept = kept(scenario)
        old = scenario[:messages].map { |m| m.except(:turn_id) }
        ranges = Samagotchi::Bridge::TurnRanges.of(old)
        records = Samagotchi::Bridge::TurnRanges.records(ranges, kept[:turns])
        drawings.valid(kept[:lines], scenario[:messages]).each do |real|
          index = ranges.index { |r| r.from == real.from && r.to == real.to }
          range = ranges[index]
          synth = described_class.line(old, range, record: records[index], tools: kept[:tools])
          expect(synth.turn_id).to start_with("m#{range.from}-")
          expect(synth.end).not_to have_key("turn_id")
          next if range.opening.nil?

          woken = range.opening < range.from
          expect(synth.end["record_id"]).to eq(real.turn_id)
          expect(comparable(synth, unopened: true, woken: woken).merge("end" => comparable(synth, woken: woken)["end"].except("turn_id")))
            .to eq(comparable(real, unopened: true, woken: woken).merge("end" => comparable(real, woken: woken)["end"].except("turn_id")))
        end
      end
    end
  end

  describe "the turn's ids" do
    let(:head) { { role: "system", content: "You are chi." } }

    it "keeps a turn's own id on its end and leaves a made-up one off it (no Revise for it)" do
      messages = [head, { role: "user", content: "old" }, { role: "model", content: "a" }]
      range = Samagotchi::Bridge::TurnRanges.of(messages).first
      line = described_class.line(messages, range)

      expect(line.turn_id).to match(/\Am1-/)
      expect(line.drawing["turn_id"]).to eq(line.turn_id)
      expect(line.end).not_to have_key("turn_id")
      expect(line.kind).to eq("completed")
      expect(line.end).not_to have_key("record_id")
    end

    it "gives a repeated turn id's later range its own line id, kept off its end" do
      messages = [head, { role: "user", content: "one", turn_id: "t1" }, { role: "model", content: "a" },
                  Samagotchi::TurnNote.failed_after("boom", 1), { role: "user", content: "one", turn_id: "t1" }, { role: "model", content: "b" }]
      first, again = Samagotchi::Bridge::TurnRanges.of(messages).map { |range| described_class.line(messages, range) }

      expect([first.turn_id, again.turn_id]).to eq(%w[t1 t1~4])
      expect(first.kind).to eq("failed")
      expect(first.end).to include("turn_id" => "t1")
      expect(again.end).not_to have_key("turn_id")
    end

    it "reads a call's status with no record from its output, as a reload did: no result, blocked, a grep's no match" do
      calls = [{ id: "c1", name: "read", arguments: '{"path":"a"}' }, { id: "c2", name: "execute", arguments: '{"command":"rm -rf b"}' },
               { id: "c3", name: "execute", arguments: '{"command":"rg zzz lib/"}' }]
      messages = [head, { role: "user", content: "go", turn_id: "t1" }, { role: "model", content: "", tool_calls: calls },
                  { role: "tool_response", content: "[execute] Error: denied by guardrail (rm): not here", tool_call_id: "c2" },
                  { role: "tool_response", content: "[execute]\nexit: 1", tool_call_id: "c3" }, { role: "model", content: "ok" }]
      line = described_class.line(messages, Samagotchi::Bridge::TurnRanges.of(messages).first)

      expect(line.drawing["parts"].select { |p| p["kind"] == "tool" }.map { |p| p["status"] }).to eq(["no result", "blocked", "ok"])
    end

    it "takes a turn's tool records by its own id when no turn record came (a join's link)" do
      messages = [head, { role: "user", content: "go", turn_id: "t1" },
                  { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: '{"path":"a"}' }] },
                  { role: "tool_response", content: "[read]\na", tool_call_id: "c1" }, { role: "model", content: "ok" }]
      tools = [{ "turn_id" => "t1", "tool" => "read", "status" => "ok", "duration_ms" => 42 }]
      line = described_class.line(messages, Samagotchi::Bridge::TurnRanges.of(messages).first, tools: tools)

      expect(line.drawing["parts"].find { |p| p["kind"] == "tool" }).to include("duration_ms" => 42)
    end

    it "draws a turn with no record without durations, its kind from its note" do
      messages = [head, { role: "user", content: "go", turn_id: "t1" },
                  { role: "model", content: "x", tool_calls: [{ id: "c1", name: "read", arguments: '{"path":"a"}' }] },
                  { role: "tool_response", content: "[read]\na", tool_call_id: "c1" },
                  Samagotchi::TurnNote.cancelled(:user, seconds: 2)]
      line = described_class.line(messages, Samagotchi::Bridge::TurnRanges.of(messages).first)

      tool = line.drawing["parts"].find { |p| p["kind"] == "tool" }
      expect(tool).to include("tool" => "read", "status" => "ok", "action" => "reading file")
      expect(tool).not_to have_key("duration_ms")
      expect(line.kind).to eq("canceled")
      expect(line.end).to include("type" => "turn_canceled", "turn_id" => "t1")
    end
  end

  describe ".memoized" do
    let(:messages) { [{ role: "system", content: "h" }, { role: "user", content: "go", turn_id: "t1" }, { role: "model", content: "x" }] }
    let(:range) { Samagotchi::Bridge::TurnRanges.of(messages).first }

    before { described_class::MEMO.clear }

    it "makes a range's line once, again when what it is made from changes" do
      allow(described_class).to receive(:safe_line).and_call_original
      first = described_class.memoized("s1", messages, range)
      expect(described_class.memoized("s1", messages, range)).to equal(first)
      expect(described_class).to have_received(:safe_line).once

      described_class.memoized("s1", messages, range, record: { "id" => "t1", "status" => "canceled" })
      described_class.memoized("s1", messages, range, entries: [{ "type" => "hook_notice", "of_turn" => "t1", "text" => "n" }])
      edited = messages[0...-1] + [{ role: "model", content: "y" }]
      described_class.memoized("s1", edited, range)
      described_class.memoized("s2", messages, range)
      expect(described_class).to have_received(:safe_line).exactly(5).times
    end

    it "keeps no more than its budget, the least recently used going first" do
      memo = described_class::Memo.new(budget: 1)
      memo.fetch(:a) { described_class.line(messages, range) }
      memo.fetch(:b) { described_class.line(messages, range) }
      expect(memo.size).to eq(1)
      expect(memo.fetch(:b) { raise "kept" }).to be_a(Samagotchi::Bridge::TurnDrawings::Line)
    end
  end

  describe "the review's cases (P0+P1)" do
    let(:head) { { role: "system", content: "You are chi." } }

    it "never raises: a non-Hash message in a range, and a minimal line that fails too, give a line" do
      messages = [head, { role: "user", content: "go", turn_id: "t1" }, "garbage", { role: "model", content: "x" }]
      range = Samagotchi::Bridge::TurnRanges.of(messages).first
      expect(described_class.safe_line(messages, range)).to be_a(Samagotchi::Bridge::TurnDrawings::Line)

      allow(described_class).to receive(:line).and_raise(ArgumentError, "boom")
      allow(described_class).to receive(:minimal).and_raise(TypeError, "again")
      line = described_class.safe_line(messages, range)
      expect(line).to have_attributes(turn_id: "t1", kind: "completed", from: 1, to: 4)
      expect(line.drawing["parts"]).to eq([])
    end

    it "reads a turn's kind from its own last note only: a restored failure after it is a range of its own" do
      messages = [head, { role: "user", content: "p1", turn_id: "t1" }, { role: "model", content: "A" },
                  Samagotchi::TurnNote.failed("down", restored: true)]
      first, failure = Samagotchi::Bridge::TurnRanges.of(messages)
      expect(described_class.line(messages, first).kind).to eq("completed")
      expect(described_class.line(messages, failure).kind).to eq("failed")
    end

    it "gives a repeated id's later range none of the turn's CardStore entries" do
      messages = [head, { role: "user", content: "one", turn_id: "t1" }, { role: "model", content: "a" },
                  Samagotchi::TurnNote.failed_after("boom", 1), { role: "user", content: "one", turn_id: "t1" }, { role: "model", content: "b" }]
      entries = [{ "type" => "hook_notice", "hook" => "h", "text" => "n", "of_turn" => "t1", "iteration" => 1, "calls" => 0 }]
      first, again = Samagotchi::Bridge::TurnRanges.of(messages).map { |r| described_class.line(messages, r, entries: entries) }
      notices = ->(line) { line.drawing["parts"].count { |p| p["kind"] == "notice" } }
      expect([notices.call(first), notices.call(again)]).to eq([1, 0])
    end

    it "raises out of the fold what it can't fold (the minimal line stands in, logged), never dropping a row quietly" do
      messages = [head, { role: "user", content: "go", turn_id: "t1" }, { role: "model", content: "x" }]
      range = Samagotchi::Bridge::TurnRanges.of(messages).first
      allow_any_instance_of(Samagotchi::Bridge::TurnAccumulator).to receive(:fold_turn_event).and_raise(ArgumentError, "bad event")
      expect { described_class.line(messages, range) }.to raise_error(ArgumentError, "bad event")
      expect(described_class.safe_line(messages, range).drawing["parts"]).to eq([])
    end
  end

  describe ".memoized keys" do
    let(:messages) do
      [{ role: "system", content: "h" }, { role: "user", content: "go", turn_id: "t1" }, { role: "model", content: "step one" },
       { role: "model", content: "done" }]
    end
    let(:range) { Samagotchi::Bridge::TurnRanges.of(messages).first }

    before { described_class::MEMO.clear }

    it "misses on an edit inside the range, not only at its ends" do
      first = described_class.memoized("s1", messages, range)
      edited = messages.dup.tap { |list| list[2] = { role: "model", content: "EDITED" } }
      expect(described_class.memoized("s1", edited, range)).not_to equal(first)
    end

    it "hits again when only an entry's listing fields changed (a later turn)" do
      entry = { "type" => "hook_notice", "hook" => "h", "text" => "n", "of_turn" => "t1", "turns_since" => 0, "current" => false }
      first = described_class.memoized("s1", messages, range, entries: [entry])
      later = entry.merge("turns_since" => 3, "opening_id" => "t9")
      expect(described_class.memoized("s1", messages, range, entries: [later])).to equal(first)
    end
  end

  describe ".safe_line" do
    it "stands in the minimal line (the opening, the end's kind, no parts) for a synth that raises, logged once" do
      messages = [{ role: "system", content: "h" }, { role: "user", content: "go", turn_id: "t1" }, { role: "model", content: "x" }]
      range = Samagotchi::Bridge::TurnRanges.of(messages).first
      allow(Samagotchi::MessageParts).to receive(:for_message).and_raise(ArgumentError, "boom")
      allow(Samagotchi::Degrade).to receive(:note).and_call_original

      line = described_class.safe_line(messages, range, record: { "id" => "t1", "status" => "failed", "failure" => { "summary" => "down" } })

      expect(line.drawing).to include("prompt" => "go", "turn_id" => "t1", "parts" => [])
      expect(line.kind).to eq("failed")
      expect(line.end).to include("type" => "turn_failed", "record_id" => "t1")
      expect(Samagotchi::Degrade).to have_received(:note).with(:web, "turn_synth_failed", an_instance_of(ArgumentError), from: 1, to: 3)
    end
  end
end
