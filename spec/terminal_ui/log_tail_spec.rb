# frozen_string_literal: true

require "tmpdir"
require "samagotchi/terminal_ui/log_tail"

RSpec.describe Samagotchi::TerminalUI::LogTail do
  let(:dir) { Dir.mktmpdir("log-tail") }
  let(:path) { File.join(dir, "samagotchi.log") }
  let(:shown) { [] }
  let(:tail) { described_class.new(path: path, session_id: "abcdef12-3456", on_record: ->(record) { shown << record }) }

  after do
    tail.stop
    FileUtils.rm_rf(dir)
  end

  def record(sid, event, payload: nil)
    Samagotchi::LogLine.format(Samagotchi::LogLine::Record.new(
      ts: Time.now, level: "DEBUG", tag: "http", pid: 1, sid: sid, event: event, fields: { "n" => 1 }, payload: payload
    ))
  end

  def append(text) = File.open(path, "a") { |io| io.write(text) }

  it "shows this session's records written after it started, with their payload, and no other session's" do
    append(record("abcdef12", "before"))
    tail.send(:open_at, :end)

    append(record("abcdef12", "response", payload: "line one\nline two") + record("99999999", "other") + record(nil, "none"))
    tail.poll

    expect(shown.map(&:event)).to eq(["response"])
    expect(shown.first.payload).to eq("line one\nline two")
  end

  it "waits for a file that isn't there yet, and reads it from its start" do
    tail.send(:open_at, :end)
    tail.poll
    append(record("abcdef12", "first"))
    tail.poll

    expect(shown.map(&:event)).to eq(["first"])
  end

  it "follows a rotation (the file renamed to .1, a new one written)" do
    append(record("abcdef12", "old"))
    tail.send(:open_at, :end)
    File.rename(path, "#{path}.1")
    append(record("abcdef12", "new"))
    tail.poll

    expect(shown.map(&:event)).to eq(["new"])
  end

  it "reads what the old file got after its last look before it follows the rotation" do
    append(record("abcdef12", "old"))
    tail.send(:open_at, :end)
    append(record("abcdef12", "late"))
    File.rename(path, "#{path}.1")
    append(record("abcdef12", "new"))
    tail.poll

    expect(shown.map(&:event)).to eq(%w[late new])
  end

  it "keeps a torn last line for the next look" do
    tail.send(:open_at, :end)
    line = record("abcdef12", "torn")
    append(line[0, 20])
    tail.poll
    expect(shown).to be_empty

    append(line[20..])
    tail.poll
    expect(shown.map(&:event)).to eq(["torn"])
  end
end
