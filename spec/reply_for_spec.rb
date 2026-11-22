# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/reply_for"
require "samagotchi/pending_question"

RSpec.describe Samagotchi::ReplyFor do
  let(:voice) { { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false } }

  describe ".parse (POST …/ask's reply_for)" do
    it "resolves a name to its values, and takes the values themselves (a missing one is full)" do
      expect(described_class.parse("voice", names: described_class::DEFAULT_NAMES).to_file).to eq(voice)
      expect(described_class.parse({ "room" => "one_line" }, names: {}).to_file)
        .to eq("formatting" => "markdown", "room" => "one_line", "choices" => "many", "detail" => true)
      expect(described_class.parse({ formatting: "plain", choices: 0 }, names: {}).choices).to eq(0)
    end

    it "is nil for none, and for values that are full everywhere: no stored \"full\"" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse({}, names: {})).to be_nil
      expect(described_class.parse(described_class::FULL, names: {})).to be_nil
      expect(described_class.parse("big", names: { "big" => { "room" => "long" } })).to be_nil
    end

    it "refuses an unknown name, key or value with one message that says which and what it may be" do
      {
        "phone" => /unknown name "phone" \(known: voice\)/,
        { "colour" => "red" } => /unknown key "colour" \(known: formatting, room, choices, detail\)/,
        { "formatting" => "rtf" } => /formatting is markdown or plain/,
        { "room" => "tiny" } => /room is long, short, one_line/,
        { "choices" => 12 } => /choices is "many" or 0..9/,
        { "choices" => "3" } => /choices is "many" or 0..9/,
        { "detail" => "no" } => /detail is true or false/,
        42 => /reply_for is a name or an object/
      }.each do |value, message|
        expect { described_class.parse(value, names: described_class::DEFAULT_NAMES) }
          .to raise_error(described_class::Invalid, message), value.inspect
      end
    end

    it "names the config entry when a configured name's values are wrong" do
      expect { described_class.parse("watch", names: { "watch" => { "room" => "huge" } }) }
        .to raise_error(described_class::Invalid, /reply_for "watch": room is/)
    end
  end

  describe ".names (config.yml's surfaces:)" do
    it "adds config.yml's names to the defaults, a name there replacing a default" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"), <<~YAML)
          surfaces:
            watch: {formatting: plain, room: one_line, choices: 2, detail: false}
            voice: {formatting: plain, room: one_line}
        YAML
        names = described_class.names(env: { "XDG_CONFIG_HOME" => dir })

        expect(names.keys).to contain_exactly("voice", "watch")
        expect(described_class.parse("watch", names: names).room).to eq("one_line")
        expect(described_class.parse("voice", names: names).to_file)
          .to eq("formatting" => "plain", "room" => "one_line", "choices" => "many", "detail" => true)
      end
    end

    it "is the defaults without a config file or a surfaces: mapping" do
      Dir.mktmpdir do |dir|
        expect(described_class.names(env: { "XDG_CONFIG_HOME" => dir })).to eq(described_class::DEFAULT_NAMES)
      end
    end
  end

  describe ".from (a carried or saved value)" do
    it "reads the values with string or symbol keys, and is nil for anything malformed or full" do
      expect(described_class.from(voice.transform_keys(&:to_sym)).to_file).to eq(voice)
      expect(described_class.from(described_class.from(voice))).to eq(described_class.from(voice))
      [nil, "voice", { "room" => "tiny" }, { "x" => 1 }, described_class::FULL, []].each do |value|
        expect(described_class.from(value)).to be_nil, value.inspect
      end
    end
  end

  describe "#line (the baked wording)" do
    it "says each restricted value once, in a fixed order, and nothing of a full one" do
      line = described_class.from(voice).line

      expect(line).to start_with("[#{described_class::LEAD}: ")
      expect(line).to include("plain spoken sentences, not lists").and include("at most 60 words")
        .and include("at most 3 choices").and include("can't show commands, code or diffs")
      expect(line.index("plain")).to be < line.index("60 words")
      expect(described_class.from("room" => "one_line").line).to include("one line of at most 80 characters")
        .and(satisfy { |text| !text.include?("plain") && !text.include?("choices") })
      expect(described_class.from("choices" => 0).line).to include("one yes-or-no question")
    end

    it "is a pure function of the values" do
      expect(described_class.from(voice).line).to eq(described_class.from(voice.to_a.reverse.to_h).line)
    end
  end

  describe ".opener_fields (the opening user message's saved fields)" do
    let(:declared) { described_class.from(voice) }
    let(:web_opener) { { role: "user", content: "hi", turn_id: "t2" } }
    let(:voice_opener) { { role: "user", content: "hi", turn_id: "t1", reply_for: voice, reply_line: declared.line } }

    it "saves a declared value's values and line" do
      expect(described_class.opener_fields([], declared)).to eq(reply_for: voice, reply_line: declared.line)
    end

    it "gives the first undeclared opener after a declared one the return line, once" do
      expect(described_class.opener_fields([voice_opener], nil)).to eq(reply_line: described_class::RETURN_LINE)
      returned = web_opener.merge(reply_line: described_class::RETURN_LINE)
      expect(described_class.opener_fields([voice_opener, { role: "model", content: "ok" }, returned], nil)).to eq({})
      expect(described_class::RETURN_LINE).to start_with("[#{described_class::LEAD}: ")
    end

    it "gives a declared opener after a declared one its own line, never the return line" do
      expect(described_class.opener_fields([voice_opener], declared)).to eq(reply_for: voice, reply_line: declared.line)
    end

    it "looks past a wake's note, a report, a steer, merged input and a !shell line to the turn before them" do
      between = [
        { role: "system", content: "[CONTEXT NOTE]", turn_start: true, turn_id: "w1" },
        { role: "user", kind: "input", content: "[Delegate report] done", turn_start: true },
        { role: "user", kind: "steer", source: "user", content: "and also" },
        { role: "user", content: "!(ls)\na.rb" }
      ]
      history = [voice_opener, { role: "model", content: "ok" }, *between]

      expect(described_class.opener_fields(history, nil)).to eq(reply_line: described_class::RETURN_LINE)
    end

    it "reads a reloaded session's string-keyed opener the same" do
      expect(described_class.opener_fields([JSON.parse(JSON.generate(voice_opener))], nil))
        .to eq(reply_line: described_class::RETURN_LINE)
    end

    it "is nothing in a session that never declared one (its bytes as they were)" do
      expect(described_class.opener_fields([web_opener, { role: "model", content: "ok" }], nil)).to eq({})
      expect(described_class.opener_fields([], nil)).to eq({})
    end
  end

  describe ".of_latest_turn (a pending question's turn, for its answer's reply)" do
    it "is the latest turn opening's value: a wake's opening declares none" do
      opener = { role: "user", content: "hi", turn_id: "t1", reply_for: voice }
      expect(described_class.of_latest_turn([opener, { role: "model", content: "?" }]).to_file).to eq(voice)
      expect(described_class.of_latest_turn([opener, { role: "system", content: "note", turn_start: true }])).to be_nil
      expect(described_class.of_latest_turn([opener, { role: "user", content: "web", turn_id: "t2" }])).to be_nil
      expect(described_class.of_latest_turn([])).to be_nil
    end
  end

  describe "#answers? (which questions a surface without detail may answer)" do
    def question(**fields) = Samagotchi::PendingQuestion.new(id: "q", question: "?", **fields)

    it "answers the model's own and the step-limit question; never an approval, a hook's or a user-only one" do
      no_detail = described_class.from(voice)
      expect(no_detail.answers?(question)).to be(true)
      expect(no_detail.answers?(question(kind: "continue"))).to be(true)
      expect(no_detail.answers?(question(kind: "approval", approval: {}))).to be(false)
      expect(no_detail.answers?(question(kind: "hook", hook: "cost-cap"))).to be(false)
      expect(no_detail.answers?(question(user_only: true))).to be(false)
      expect(no_detail.needs_detail_text(question(kind: "approval"))).to eq("chi needs an approval: open it on a full screen.")
    end

    it "answers anything with detail" do
      expect(described_class.from("formatting" => "plain").answers?(question(kind: "approval", user_only: true))).to be(true)
    end
  end
end
