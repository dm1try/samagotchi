# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/broadcast/triage_log"

RSpec.describe Samagotchi::Broadcast::TriageLog do
  let(:dir) { Dir.mktmpdir("triage-log") }
  let(:path) { File.join(dir, "broadcast", "log.jsonl") }
  let(:log) { described_class.new(path) }
  let(:at) { Time.at(1_780_000_000) }

  after { FileUtils.rm_rf(dir) }

  def entry(session, result = "skipped")
    described_class::Entry.new(session: session, result: result, p: 0.1, reason: "model: no", by: "model", tags: [])
  end

  def add(id, text: "note")
    log.append_broadcast(id: id, at: at, text: text, note_tags: [], triage_model: "small", recipients: [entry("s1")])
  end

  it "is under the state dir's broadcast folder" do
    expect(described_class.default_path(env: { "XDG_STATE_HOME" => "/x/state" })).to eq("/x/state/samagotchi/broadcast/log.jsonl")
  end

  it "reads back broadcasts with their corrections, skipping lines that don't parse" do
    add("b-11111111")
    File.write(path, "not json\n{\"no\": \"id\"}\n", mode: "a")
    log.append_correction(id: "b-11111111", at: at + 60, sessions: [described_class::Delivery.new(session: "s1", result: "delivered")])
    log.append_correction(id: "b-99999999", at: at, sessions: [])

    records = log.records
    expect(records.map(&:id)).to eq(["b-11111111"])
    expect(records.first).to have_attributes(at: at, text: "note", triage_model: "small")
    expect(records.first.recipients).to eq([entry("s1")])
    expect(records.first.corrections.map(&:at)).to eq([at + 60])
    expect(records.first.delivered?("s1")).to be(true)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "keeps one old file when it grows past MAX_BYTES, and still reads both" do
    stub_const("#{described_class}::MAX_BYTES", 100)
    add("b-11111111", text: "x" * 200)
    add("b-22222222")
    add("b-33333333")

    expect(File.exist?("#{path}.1")).to be(true)
    expect(log.records.map(&:id)).to eq(%w[b-22222222 b-33333333])
  end

  it "rotates once when broadcasts append at the same time: the size check and the rename are under the lock" do
    stub_const("#{described_class}::MAX_BYTES", 2000)
    add("b-00000000", text: "x" * 2000)
    # Widens the window between the size check and the rename.
    allow(File).to(receive(:size).and_wrap_original { |original, *args| original.call(*args).tap { sleep 0.05 } })

    threads = %w[b-11111111 b-22222222 b-33333333 b-44444444].map { |id| Thread.new { add(id) } }
    threads.each(&:join)

    expect(File.readlines("#{path}.1").map { |line| JSON.parse(line)["id"] }).to eq(["b-00000000"])
    expect(File.readlines(path).map { |line| JSON.parse(line)["id"] }).to match_array(%w[b-11111111 b-22222222 b-33333333 b-44444444])
  end

  it "finds a broadcast by its id, without b-, or the start of one, and says when that is ambiguous" do
    add("b-1234abcd")
    add("b-1299ffff")

    expect(log.find("b-1234abcd").id).to eq("b-1234abcd")
    expect(log.find("1234").id).to eq("b-1234abcd")
    expect { log.find("12") }.to raise_error(described_class::NotFound, /12 names 2 broadcasts/)
    expect { log.find("b-77") }.to raise_error(described_class::NotFound, "no broadcast b-77 in the log (chi broadcast log)")
  end
end
