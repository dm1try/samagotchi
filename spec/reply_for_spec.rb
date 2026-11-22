# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/reply_for"

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

    it "saves a declared value's values and line" do
      expect(described_class.opener_fields([], declared)).to eq(reply_for: voice, reply_line: declared.line)
    end

    it "is nothing in a session that never declared one (its bytes as they were)" do
      expect(described_class.opener_fields([web_opener, { role: "model", content: "ok" }], nil)).to eq({})
      expect(described_class.opener_fields([], nil)).to eq({})
    end
  end
end
