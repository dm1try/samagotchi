# frozen_string_literal: true

require "spec_helper"
require "samagotchi/inline_widgets"

# A ```chi-ui fence's YAML: what the page draws, or why it stays source.
RSpec.describe Samagotchi::InlineWidgets do
  def parse(source) = described_class.parse(source)

  def picks(rows_yaml)
    "type: picks\ntitle: Findings\nrows:\n#{rows_yaml}"
  end

  def walk(steps_yaml, actors: "[user, web]")
    "type: walk\ntitle: A tab reconnects\nactors: #{actors}\nsteps:\n#{steps_yaml}"
  end

  def row
    <<~YAML.gsub(/^/, "  ")
      - id: "1"
        text: Bridge drops the replay buffer
        options:
          - fix now
          - skip
        recommended: fix now
    YAML
  end

  describe "the eval's blocks (0013-inline-widgets, spec/fixtures/inline_widgets)" do
    dir = File.expand_path("fixtures/inline_widgets", __dir__)
    manifest = YAML.load_file(File.join(dir, "manifest.yml"))

    it "has all 78 (47 from round 2, 31 from round 1)" do
      expect(manifest.size).to eq(78)
      expect(manifest.keys.count { |name| name.start_with?("r2-") }).to eq(47)
      expect(manifest.keys).to match_array(Dir.children(dir) - ["manifest.yml"])
    end

    it "gives each the manifest's outcome" do
      got = manifest.to_h do |name, _want|
        widget = parse(File.read(File.join(dir, name)))
        [name, if widget.ok?
                 widget.lenient? ? "lenient" : "ok"
               else
                 "error"
               end]
      end
      expect(got).to eq(manifest)
    end

    it "draws all 47 of round 2's" do
      drawn = manifest.count { |name, outcome| name.start_with?("r2-") && outcome != "error" }
      expect(drawn).to eq(47)
    end
  end

  describe "a picks" do
    it "normalises: string keys, ids as strings, unknown keys dropped" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: 1
          text: Bridge drops the replay buffer
          options: [fix, skip]
          recommended: fix
          why: a slow tab loses events
          color: red
      YAML

      expect(widget).to be_ok
      expect(widget).not_to be_lenient
      expect(widget.type).to eq("picks")
      expect(widget.data).to eq("title" => "Findings", "rows" => [{ "id" => "1", "text" => "Bridge drops the replay buffer",
                                                                    "options" => %w[fix skip], "recommended" => "fix",
                                                                    "why" => "a slow tab loses events" }])
      expect(JSON.parse(widget.widget_json)).to eq({ "type" => "picks" }.merge(widget.data))
    end

    it "keeps strings strings, where YAML 1.1 would make yes/no booleans, 1.10 a float and a date a Date" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: 1.10
          text: 2026-11-07
          options: [yes, no, on, ~x]
          recommended: no
      YAML

      expect(widget).to be_ok
      expect(widget.data["rows"].first).to include("id" => "1.10", "text" => "2026-11-07",
                                                   "options" => %w[yes no on ~x], "recommended" => "no")
    end

    it "takes an option or a free-text value YAML read as a one-pair mapping as the text written, and marks it lenient" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: "1"
          text: Push title includes the command
          options:
            - fix now: drop the  command é
            - skip
          recommended: "fix now: drop the  command é"
          why: {a: b}
      YAML

      expect(widget).to be_ok
      expect(widget).to be_lenient
      expect(widget.data["rows"].first).to include("options" => ["fix now: drop the  command é", "skip"], "why" => "a: b")
    end

    it "folds a pair written over lines as key: value" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: "1"
          text: Push title
          options:
            - fix now: drop
                the command
            - skip
      YAML

      expect(widget.data["rows"].first["options"]).to eq(["fix now: drop the command", "skip"])
    end

    it "refuses options as mappings of several pairs or of a list, and a fold where an id or an actor goes" do
      several = "    - id: \"1\"\n      text: t\n      options:\n        - {a: b, c: d}\n        - skip\n"
      nested = "    - id: \"1\"\n      text: t\n      options:\n        - a: [b]\n        - skip\n"
      id = "    - id: {a: b}\n      text: t\n      options: [x, y]\n"

      expect(parse(picks(several)).error).to eq("row 1's option must be text, not a mapping")
      expect(parse(picks(nested)).error).to eq("row 1's option must be text, not a mapping")
      expect(parse(picks(id)).error).to eq("row 1's id must be text, not a mapping")
    end

    it "refuses a recommended that isn't an option, a duplicate id, and the option count" do
      expect(parse(picks(row.sub("recommended: fix now", "recommended: later"))).error)
        .to eq('row 1: recommended "later" isn\'t one of its options')
      expect(parse(picks(row + row)).error).to eq('row id "1" is used twice')
      expect(parse(picks(row.sub(/^ *- skip\n/, ""))).error).to eq("row 1 has 1 options (2-4)")
      five = row.sub(/^( *)- skip\n/, "\\1- skip\n\\1- a\n\\1- b\n\\1- c\n")
      expect(parse(picks(five)).error).to eq("row 1 has 5 options (2-4)")
    end

    it "takes a value with a colon in it, through the lenient pass" do
      widget = parse(picks(row.sub("text: Bridge drops the replay buffer", "text: Asked: drop the buffer?")))

      expect(widget).to be_ok
      expect(widget).to be_lenient
      expect(widget.data["rows"].first["text"]).to eq("Asked: drop the buffer?")
    end

    it "takes an option with a colon in it, through the lenient pass, when that is what breaks the YAML" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: D1
          text: "keep the file: how long"
          options:
            - A: delete at exit
            - B: keep 1 h
          recommended: "B: keep 1 h"
          why: a: b
      YAML

      expect(widget).to be_ok
      expect(widget).to be_lenient
      expect(widget.data["rows"].first).to include("options" => ["A: delete at exit", "B: keep 1 h"], "why" => "a: b")
    end

    it "keeps a quoted value's escapes as written in the lenient pass (L2, as it is)" do
      widget = parse(picks(row.sub("text: Bridge drops the replay buffer", %(text: "say \\"hi\\" now"\n    why: a: b))))

      expect(widget).to be_lenient
      expect(widget.data["rows"].first["text"]).to eq('say \\"hi\\" now')
    end

    it "matches within a line: the indent before a value or an item never spans a blank line" do
      lenient = Samagotchi::InlineWidgets::Lenient
      expect("a\n\n  - x\n".match(lenient::ITEM)[1]).to eq("  - ")
      expect("a\n\n  text: x\n".match(lenient::VALUE)[1]).to eq("  text: ")
    end

    it "takes a value that starts with a quoted word, through the lenient pass" do
      widget = parse(picks(row.sub("text: Bridge drops the replay buffer", 'text: "reset" drops the buffer')))

      expect(widget).to be_lenient
      expect(widget.data["rows"].first["text"]).to eq('"reset" drops the buffer')
    end

    it "splits a flow list at its commas, as YAML does, so a comma in an option changes the count" do
      widget = parse(picks(row.sub(/options:\n.*- skip/m, "options: [A allow, B deny project, allow system]")
                             .sub("recommended: fix now", "recommended: B deny project, allow system")))

      expect(widget.error).to eq('row 1: recommended "B deny project, allow system" isn\'t one of its options')
    end

    it "caps the rows at 12 and every string at 300 characters" do
      rows = (1..13).map { |n| row.sub('id: "1"', "id: \"#{n}\"") }.join
      expect(parse(picks(rows)).error).to eq("picks has 13 rows (at most 12)")
      expect(parse(picks(row.sub("Bridge drops the replay buffer", "x" * 301))).error).to eq("row 1's text is over 300 characters")
      expect(parse(picks(row.sub("Bridge drops the replay buffer", "x" * 300)))).to be_ok
    end
  end

  describe "a walk" do
    def steps
      <<~YAML.gsub(/^/, "  ")
        - id: s1
          actor: user
          does: reopens the laptop
          sees: reconnecting
          behind: GET /events
        - id: s2
          actor: web
          does: checks the id
          cases:
            - when: buffered
              goto: s3
            - when: too old
              goto: s1
        - id: s3
          actor: web
          sees: the missed events
          next: s1
      YAML
    end

    it "normalises its steps" do
      widget = parse(walk(steps))

      expect(widget).to be_ok
      expect(widget.data).to eq(
        "title" => "A tab reconnects", "actors" => %w[user web],
        "steps" => [
          { "id" => "s1", "actor" => "user", "does" => "reopens the laptop", "sees" => "reconnecting", "behind" => "GET /events" },
          { "id" => "s2", "actor" => "web", "does" => "checks the id",
            "cases" => [{ "when" => "buffered", "goto" => "s3" }, { "when" => "too old", "goto" => "s1" }] },
          { "id" => "s3", "actor" => "web", "sees" => "the missed events", "next" => "s1" }
        ]
      )
    end

    it "takes a step with sees and no does" do
      expect(parse(walk(steps)).data["steps"].last).not_to have_key("does")
      expect(parse(walk(steps.sub("    sees: the missed events\n", ""))).error).to eq("step s3 needs does or sees")
    end

    it "takes round 1's branches as cases" do
      widget = parse(walk(steps.sub("cases:", "branches:")))

      expect(widget.data["steps"][1]["cases"]).to eq([{ "when" => "buffered", "goto" => "s3" }, { "when" => "too old", "goto" => "s1" }])
    end

    it "refuses a goto or a next that names no step, a duplicate id, and an unknown actor" do
      expect(parse(walk(steps.sub("goto: s3", "goto: s9"))).error).to eq('step s2: "s9" isn\'t a step')
      expect(parse(walk(steps.sub("next: s1", "next: s0"))).error).to eq('step s3: "s0" isn\'t a step')
      expect(parse(walk(steps.sub("id: s3", "id: s2"))).error).to eq('step id "s2" is used twice')
      expect(parse(walk(steps.sub("actor: web", "actor: worker"))).error).to eq('step s2: actor "worker" isn\'t one of the actors')
    end

    it "caps the actors at 2-5 and the steps at 30" do
      expect(parse(walk(steps, actors: "[user]")).error).to eq("walk has 1 actors (2-5)")
      expect(parse(walk(steps, actors: "[user, web, a, b, c, d]")).error).to eq("walk has 6 actors (2-5)")
      expect(parse(walk(steps, actors: "[user, web, user]")).error).to eq('actor "user" is listed twice')
      many = (1..31).map { |n| "  - id: s#{n}\n    actor: user\n    does: x\n" }.join
      expect(parse(walk(many)).error).to eq("walk has 31 steps (at most 30)")
    end
  end

  describe "what isn't plain data" do
    it "refuses a YAML alias or anchor, before the lenient pass" do
      widget = parse(picks(<<~YAML.gsub(/^/, "  ")))
        - id: "1"
          text: &t Bridge drops the buffer
          options: [fix, skip]
        - id: "2"
          text: *t
          options: [fix, skip]
      YAML

      expect(widget.error).to eq("YAML aliases and anchors aren't allowed")
      expect(widget).not_to be_lenient
    end

    it "refuses a tag, without repeating it" do
      expect(parse("type: picks\nrows: !ruby/object:Object {}\n").error).to eq("YAML tags aren't allowed")
      expect(parse("type: !#{"x" * 15_000} picks\n").error).to eq("YAML tags aren't allowed")
    end

    it "repeats at most 40 characters of a bad type" do
      expect(parse("type: #{"x" * 15_000}\n").error).to eq("unknown type #{("x" * 40).inspect}... (picks or walk)")
    end

    it "refuses a block that nests too deep, in a thread's smaller stack too" do
      deep = "type: picks\nrows: #{"[" * 1000}#{"]" * 1000}\n"

      expect(Thread.new { parse(deep) }.value.error).to eq("the block nests too deep")
      expect(parse("type: picks\nrows: #{"[" * 8}#{"]" * 8}\n").error).to eq("the block nests too deep")
    end

    it "falls back on a stack overflow it didn't see coming" do
      allow(Samagotchi::InlineWidgets::Schema).to receive(:new).and_raise(SystemStackError)

      expect(parse(picks(row)).error).to eq("the block nests too deep")
    end

    it "refuses text that isn't valid UTF-8" do
      expect(parse("type: picks\ntitle: \xFF\n".b).error).to eq("the block is not valid text (UTF-8)")
    end

    it "refuses a root that isn't a mapping, an unknown type, more than one document and an empty block" do
      expect(parse("- type: picks\n").error).to eq("the block isn't a mapping (type: picks or walk first)")
      expect(parse("just words\n").error).to eq("the block isn't a mapping (type: picks or walk first)")
      expect(parse("type: table\n").error).to eq('unknown type "table" (picks or walk)')
      expect(parse("title: x\n").error).to eq("the block needs type: picks or walk")
      expect(parse("type: [a]\n").error).to eq("unknown type (not text) (picks or walk)")
      expect(parse("? [a]\n: b\n").error).to eq("a key must be a plain word")
      expect(parse("type: picks\n---\ntype: walk\n").error).to eq("one YAML document only")
      expect(parse("").error).to eq("the block is empty")
    end

    it "refuses a block over 16 KB before reading it" do
      expect(Psych).not_to receive(:parse_stream)

      expect(parse("#" * ((16 * 1024) + 1)).error).to eq("the block is over 16 KB")
    end

    it "says where YAML the lenient pass couldn't mend breaks" do
      widget = parse("type: picks\nrows:\n  - id: [1\n")

      expect(widget.error).to eq("not YAML: did not find expected ',' or ']' at line 3")
    end
  end
end
