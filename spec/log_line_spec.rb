# frozen_string_literal: true

require "samagotchi/log_line"
require "stringio"

RSpec.describe Samagotchi::LogLine do
  let(:time) { Time.utc(2026, 9, 25, 10, 11, 12.345r) }

  def record(**overrides)
    described_class::Record.new(ts: time, level: "INFO", tag: "worker", pid: 42, sid: "abcd1234",
                                event: "idle_exit", fields: { "idle_s" => 1800 }, payload: nil, **overrides)
  end

  describe ".format" do
    it "writes the header: ts with ms, padded level, tag, pid, sid, event, fields" do
      expect(described_class.format(record))
        .to eq("2026-09-25T10:11:12.345Z INFO  worker pid=42 sid=abcd1234 idle_exit idle_s=1800\n")
    end

    it "leaves sid out when there is none" do
      expect(described_class.format(record(sid: nil))).to start_with("2026-09-25T10:11:12.345Z INFO  worker pid=42 idle_exit ")
    end

    it "quotes values with spaces, quotes, = or control characters as JSON strings" do
      line = described_class.format(record(fields: { "msg" => "hook failed: \"x\"\nnext", "a" => "k=v", "e" => "\e[31mred" }))

      expect(line).to include(%q(msg="hook failed: \"x\"\nnext" a="k=v" e="\u001b[31mred"))
      expect(line.count("\n")).to eq(1)
    end

    it "indents every payload line by four spaces and escapes controls there" do
      line = described_class.format(record(payload: "one\r\n\e[1mtwo\n"))

      expect(line.lines.drop(1)).to eq(["    one\n", "    \\e[1mtwo\n", "    \n"])
    end

    it "scrubs invalid UTF-8" do
      line = described_class.format(record(fields: { "out" => "a\xFFb".b }, payload: "x\xFE".b))

      expect(line).to be_valid_encoding
      expect(line).to include("out=a?b", "    x?")
    end
  end

  describe ".parse / .each_record round trip" do
    it "reads back what format wrote" do
      original = record(fields: { "msg" => "two words", "n" => "3", "url" => "https://x.test/v1" },
                        payload: "line 1\n  indented line 2")
      parsed = described_class.each_record(StringIO.new(described_class.format(original))).to_a

      expect(parsed.size).to eq(1)
      expect(parsed.first.to_h).to eq(ts: "2026-09-25T10:11:12.345Z", level: "INFO", tag: "worker", pid: 42,
                                      sid: "abcd1234", event: "idle_exit",
                                      fields: { "msg" => "two words", "n" => "3", "url" => "https://x.test/v1" },
                                      payload: "line 1\n  indented line 2")
      expect(described_class.format(parsed.first)).to eq(described_class.format(original))
    end

    it "round-trips hostile values" do
      hostile = ["", " ", "\"", "\\", "a=b", "\u2028", "\u009b", "tab\there", "ünï", "}{", "\\\"\n"]
      hostile.each do |value|
        line = described_class.format(record(fields: { "v" => value }))
        expect(described_class.parse(line).fields).to eq("v" => value), "value #{value.inspect} → #{line}"
      end
    end

    it "keeps records of several processes apart and reports lines it can't read" do
      log = [described_class.format(record(pid: 1, payload: "p1")),
             "[2026-05-01T00:00:00Z] [verbose] an older line\n",
             described_class.format(record(pid: 2, level: "ERROR"))].join
      invalid = []

      records = described_class.each_record(StringIO.new(log), on_invalid: ->(l) { invalid << l }).to_a

      expect(records.map { |r| [r.pid, r.level, r.payload] }).to eq([[1, "INFO", "p1"], [2, "ERROR", nil]])
      expect(invalid).to eq(["[2026-05-01T00:00:00Z] [verbose] an older line"])
    end

    it "is nil for a line that isn't a header" do
      expect(described_class.parse("    payload")).to be_nil
      expect(described_class.parse("2026-09-25T10:11:12.345Z INFO  worker pid=1 ev bad field")).to be_nil
    end

    it "splits into awk-friendly columns: $3 is the tag" do
      expect(described_class.format(record(level: "WARN")).split[2]).to eq("worker")
      expect(described_class.format(record(level: "DEBUG")).split[2]).to eq("worker")
    end
  end
end
