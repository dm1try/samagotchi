# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/bridge/turn_accumulator"
require "samagotchi/bridge/turn_drawings"
require "samagotchi/text_diff"
require "support/turn_drawing_scenarios"

RSpec.describe Samagotchi::Bridge::TurnDrawings do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, described_class::FILE) }

  after { FileUtils.rm_rf(dir) }

  # The scenario's events through a real accumulator, its hook writing
  # the lines against the session's messages at each end.
  def draw(scenario)
    ends = scenario[:ends].dup
    messages = nil
    drawings = described_class.new(path: path, messages: -> { messages })
    accumulator = Samagotchi::Bridge::TurnAccumulator.new(on_turn_end: drawings.method(:append))
    scenario[:events].each do |event|
      messages = ends.shift if Samagotchi::Events::TURN_END.include?(event[:type])
      accumulator.call(event)
    end
    drawings
  end

  def lines = described_class.parse(File.read(path))

  def end_event(from: 1, to: 3, **extra) = { type: :turn_completed, turn_id: "t1", kept_from: from, kept_to: to, **extra }

  def messages = [{ role: "system", content: "head" }, { role: "user", content: "hi", at: "T0" }, { role: "model", content: "ok" }]

  describe "the shared scenarios (spec/shared/turn_drawings)" do
    TurnDrawingScenarios.all.each do |scenario|
      it "draws #{scenario[:name]} as its fixture has it" do
        draw(scenario)
        written = lines
        valid = described_class.valid(written, scenario[:messages])
        drawn = valid.to_h do |line|
          turn = Samagotchi::Bridge::TurnAccumulator.from_wire(line.drawing)
          [line.turn_id, { events: Samagotchi::Bridge::TurnAccumulator.replay_events(turn, cards: true), end: line.end }]
        end
        fixture = TurnDrawingScenarios.wire(
          description: scenario[:description], events: scenario[:events], messages: scenario[:messages],
          lines: written.map(&:to_h), drawn: drawn
        )
        file = TurnDrawingScenarios.path(scenario[:name])
        saved = File.exist?(file) ? JSON.parse(File.read(file)) : {}
        if ENV["UPDATE_TURN_DRAWINGS"]
          FileUtils.mkdir_p(File.dirname(file))
          File.write(file, "#{JSON.pretty_generate(saved.merge(fixture))}\n")
        else
          expect(saved.slice(*fixture.keys)).to eq(fixture), "run with UPDATE_TURN_DRAWINGS=1 to write #{file}"
        end
        expect(written).not_to be_empty
      end
    end

    it "keeps the newest of a rollback's and a re-run's overlapping lines" do
      scenario = TurnDrawingScenarios.all.find { |s| s[:name] == "rollback_rerun" }
      draw(scenario)

      expect(lines.map(&:turn_id)).to eq(%w[turn-first turn-second])
      expect(described_class.valid(lines, scenario[:messages]).map(&:turn_id)).to eq(%w[turn-second])
    end

    it "draws an in-turn card in its place, its latest version, and the reminder that went in" do
      card = draw(TurnDrawingScenarios.all.find { |s| s[:name] == "checkin_card" })
      kinds = card.last.drawing["parts"].map { |part| part["kind"] }
      expect(kinds).to eq(%w[generation text tool card generation text])
      reminder = draw(TurnDrawingScenarios.all.find { |s| s[:name] == "reminder_only" }).last
      expect(reminder.drawing["parts"].first).to eq("kind" => "reminder", "reminders" => [{ "name" => "tea" }])
      expect(reminder.drawing).to include("prompt" => nil)
    end
  end

  describe "#append" do
    let(:drawings) { described_class.new(path: path, messages: -> { messages }) }

    it "writes one line from the end event's range, both ends digested, the end's display keys only" do
      drawings.append({ prompt: "hi", turn_id: "t1", parts: [], pending_question: nil, event_seq: 9 },
                      end_event(duration_ms: 5, result: "x", turn_summary: { output: "ok" }))

      line = lines.fetch(0)
      expect(line.to_h).to include("v" => 1, "turn_id" => "t1", "kind" => "completed", "from" => 1, "to" => 3,
                                   "from_digest" => described_class.digest(messages[1]),
                                   "to_digest" => described_class.digest(messages[2]))
      expect(line.drawing).to eq("prompt" => "hi", "turn_id" => "t1", "parts" => [])
      expect(line.end).to eq("type" => "turn_completed", "turn_id" => "t1", "duration_ms" => 5)
      expect(drawings.last).to eq(line)
    end

    it "keeps an empty answer's notice from the summary" do
      drawings.append({ prompt: "hi", parts: [] }, end_event(turn_summary: { output: "", empty_answer: { retries: 1 } }))
      expect(lines.fetch(0).end).to include("turn_summary" => { "empty_answer" => { "retries" => 1 } })
    end

    it "writes nothing without a range, with an empty one, or past the messages" do
      drawings.append({ prompt: "hi", parts: [] }, { type: :turn_completed, turn_id: "t1" })
      drawings.append({ prompt: "hi", parts: [] }, end_event(from: 3, to: 3))
      drawings.append({ prompt: "hi", parts: [] }, end_event(from: 1, to: 9))

      expect(File.exist?(path)).to be(false)
      expect(drawings.last).to be_nil
    end

    it "logs and never raises when the write fails" do
      allow(File).to receive(:open).and_raise(Errno::ENOSPC)
      allow(Samagotchi::Log).to receive(:warn)

      expect { drawings.append({ prompt: "hi", parts: [] }, end_event) }.not_to raise_error
      expect(Samagotchi::Log).to have_received(:warn).with(:bridge, "turn_drawing_failed", error: a_string_including("ENOSPC"))
    end

    it "starts a new line after a torn last one, so both parse apart" do
      File.write(path, %({"v":1,"turn_id":"t0","kind":"completed","from":1,"to":3,"from_di))
      drawings.append({ prompt: "hi", parts: [] }, end_event)

      expect(File.read(path).lines.size).to eq(2)
      expect(lines.map(&:turn_id)).to eq(["t1"])
    end

    it "keeps a part's diff as the saved tool_diffs have it: TextDiff's cut" do
      big = "#{(1..5000).map { |n| "line #{n}" }.join("\n")}\n"
      diff = Samagotchi::TextDiff.unified("", big)
      drawings.append({ prompt: "hi", parts: [{ kind: "tool", diff: diff }] }, end_event)

      kept = lines.fetch(0).drawing["parts"].first["diff"]
      expect(kept["text"].bytesize).to be <= Samagotchi::TextDiff::MAX_BYTES + 200
      expect(kept["text"].lines.size).to be <= Samagotchi::TextDiff::MAX_LINES + 1
    end

    it "starts from the file's last line (#last), a torn tail skipped" do
      drawings.append({ prompt: "hi", parts: [] }, end_event)
      File.write(path, %({"v":1,"tur), mode: "a")

      expect(described_class.new(path: path, messages: -> { messages }).last&.turn_id).to eq("t1")
    end
  end

  describe ".digest" do
    it "is the same for the live message (symbol keys, raw bytes) and the saved one (string keys, scrubbed)" do
      bad = +"caf\xC3"
      live = { role: :user, content: bad.force_encoding(Encoding::BINARY), at: "T0", turn_id: "x" }
      saved = JSON.parse(JSON.generate("role" => "user", "content" => "caf?", "at" => "T0"))

      expect(described_class.digest(live)).to eq(described_class.digest(saved))
      expect(described_class.digest(live)).not_to eq(described_class.digest(saved.merge("content" => "cafe")))
    end

    it "digests a structured content alike from either key form" do
      live = { role: "user", content: [{ type: "text", text: "a" }] }
      expect(described_class.digest(live)).to eq(described_class.digest(TurnDrawingScenarios.wire(live)))
    end
  end

  describe ".valid" do
    def line(id, from, to, list = messages)
      described_class::Line.new(v: 1, turn_id: id, kind: "completed", from: from, to: to,
                                from_digest: described_class.digest(list[from]), to_digest: described_class.digest(list[to - 1]),
                                drawing: {}, end: {})
    end

    it "keeps a line whose range is still in the messages with both ends the same" do
      expect(described_class.valid([line("t1", 1, 3)], messages).map(&:turn_id)).to eq(["t1"])
    end

    it "drops one after a rollback (a shorter list) or a changed end" do
      expect(described_class.valid([line("t1", 1, 3)], messages.first(2))).to eq([])
      changed = messages.dup.tap { |list| list[2] = { role: "model", content: "other" } }
      expect(described_class.valid([line("t1", 1, 3)], changed)).to eq([])
    end

    it "lets the newest line win an overlap and a turn id, ordered by range" do
      longer = messages + [{ role: "user", content: "next" }, { role: "model", content: "done" }]
      older = line("t1", 1, 3, longer)
      newer = line("t2", 1, 3, longer)
      later = line("t3", 3, 5, longer)
      again = line("t3", 3, 5, longer)

      expect(described_class.valid([older, later, newer], longer)).to eq([newer, later])
      expect(described_class.valid([later, again], longer)).to eq([again])
    end

    it "reads string-keyed messages (the session file) as the live ones" do
      expect(described_class.valid([line("t1", 1, 3)], TurnDrawingScenarios.wire(messages)).size).to eq(1)
    end
  end

  describe ".read" do
    it "skips an unknown version, a broken line and one missing a field" do
      good = described_class::Line.new(v: 1, turn_id: "t1", kind: "completed", from: 1, to: 3, from_digest: "a", to_digest: "b",
                                       drawing: {}, end: {})
      File.write(path, [JSON.generate(good.to_h.merge("v" => 2)), "{not json", JSON.generate(good.to_h.except("to_digest")),
                        JSON.generate(good.to_h)].join("\n") + "\n")

      expect(described_class.read(dir)).to eq([good])
    end

    it "gives [] without a file" do
      expect(described_class.read(dir)).to eq([])
    end

    it "parses the file again only when it changed" do
      drawings = described_class.new(path: path, messages: -> { messages })
      drawings.append({ prompt: "hi", parts: [] }, end_event)
      allow(described_class).to receive(:parse).and_call_original

      2.times { described_class.read(dir) }
      expect(described_class).to have_received(:parse).once
      drawings.append({ prompt: "hi", parts: [] }, end_event(turn_id: "t2"))
      expect(described_class.read(dir).map(&:turn_id)).to eq(%w[t1 t2])
      expect(described_class).to have_received(:parse).twice
    end
  end
end
