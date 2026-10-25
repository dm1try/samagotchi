# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/system_one/log"

RSpec.describe Samagotchi::SystemOne::Log do
  let(:state_dir) { File.realpath(Dir.mktmpdir("system-one-log")) }
  let(:dir) { File.join(state_dir, "samagotchi", "guardrails") }
  let(:log) { described_class.new(dir: dir) }
  let(:path) { File.join(dir, "judgments.jsonl") }

  after { FileUtils.rm_rf(state_dir) }

  def lines
    File.readlines(path).map(&:strip).reject(&:empty?)
  end

  it "appends a judgment line and returns its id" do
    id = log.judgment(rule: "git-push", source: "config", tool: "execute", p: 0.97)
    expect(id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    expect(lines.size).to eq(1)
    expect(JSON.parse(lines.first)).to include("kind" => "judgment", "id" => id, "rule" => "git-push", "p" => 0.97)
    expect(JSON.parse(lines.first)["at"]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/)
  end

  it "creates the directory beside the approvals store and writes the file 0600" do
    log.judgment(rule: "git-push")
    expect(File.exist?(path)).to be true
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    log.label("j1", "deny")
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "joins each judgment with its label, the last one winning" do
    first = log.judgment(rule: "git-push")
    second = log.judgment(rule: "git-rebase")
    log.label(first, "allow_once")
    log.label(first, "should_have_asked")
    entries = log.entries
    expect(entries.map { |entry| entry["id"] }).to eq([first, second])
    expect(entries[0]).to include("kind" => "judgment", "rule" => "git-push", "answer" => "should_have_asked")
    expect(entries[1]["answer"]).to be_nil
  end

  it "holds an exclusive flock on the file while it writes" do
    locks = []
    allow_any_instance_of(File).to receive(:flock).and_wrap_original do |original, mode|
      locks << mode
      original.call(mode)
    end
    id = log.judgment(rule: "git-push")
    log.label(id, "allow_once")
    expect(locks).to eq([File::LOCK_EX, File::LOCK_EX])
  end

  it "waits while another handle holds the file" do
    log.judgment(rule: "git-push")
    File.open(path, File::RDWR) do |held|
      held.flock(File::LOCK_EX)
      writer = Thread.new { log.judgment(rule: "git-rebase") }
      sleep 0.2 # sleep-ok: holding the lock is the behaviour; the pause is where the write must still be waiting
      expect(writer.alive?).to be true
      expect(File.readlines(path).size).to eq(1)
      held.flock(File::LOCK_UN)
      join!(writer, "the judgment that waited for the lock")
    end
    expect(File.readlines(path).size).to eq(2)
  end

  it "appends from several threads without losing or mixing a line" do
    threads = Array.new(8) { |n| Thread.new { 25.times { log.judgment(rule: "rule-#{n}") } } }
    threads.each { |thread| join!(thread, "a thread's appends") }
    expect(log.entries.size).to eq(200)
    expect(log.entries.map { |entry| entry["rule"] }.tally).to eq((0..7).to_a.map { |n| ["rule-#{n}", 25] }.to_h)
  end

  it "keeps the newest half of the lines once the file passes the cap" do
    total = 1200
    FileUtils.mkdir_p(dir)
    File.write(path, Array.new(total) { |i| JSON.generate({ "kind" => "judgment", "id" => "j#{i}", "at" => "2026-10-27T00:00:00Z", "call" => "x" * 6000 }) }.join("\n") + "\n")
    expect(File.size(path)).to be > described_class::MAX_BYTES

    newest = log.judgment(rule: "git-push")
    entries = log.entries
    expect(File.size(path)).to be <= described_class::MAX_BYTES
    expect(entries.size).to eq(total / 2)
    expect(entries.first["id"]).to eq("j#{total - (total / 2) + 1}")
    expect(entries.last["id"]).to eq(newest)
  end

  it "skips a line that doesn't parse" do
    id = log.judgment(rule: "git-push")
    File.write(path, File.read(path) + "not json at all\n" + JSON.generate({ "kind" => "label", "id" => id, "answer" => "allow_once" }) + "\n")
    expect(log.entries.size).to eq(1)
    expect(log.entries.first["id"]).to eq(id)
  end

  it "warns instead of raising when the file can't be written, and the ask goes on" do
    FileUtils.mkdir_p(dir)
    FileUtils.mkdir_p(path) # a directory where the log wants to be
    expect(Samagotchi::Log).to receive(:warn).with(:guardrails, "system_one_log_failed",
                                                   hash_including(echo: /judgments\.jsonl/)).at_least(:once)
    expect(log.judgment(rule: "git-push")).to be_nil
    expect(log.label("j1", "deny")).to be false
    expect(log.entries).to eq([])
  end

  it "warns instead of raising when the file disappears mid-read" do
    log.judgment(rule: "git-push")
    allow(Samagotchi::Log).to receive(:warn)
    expect_any_instance_of(File).to receive(:each_line).and_raise(SystemCallError, "EIO")
    expect(log.entries).to eq([])
    expect(Samagotchi::Log).to have_received(:warn).with(:guardrails, "system_one_log_failed", hash_including(echo: /system one log/))
  end
end
