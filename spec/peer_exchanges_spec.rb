# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/session"
require "samagotchi/peer_exchanges" if File.exist?(File.expand_path("../lib/samagotchi/peer_exchanges.rb", __dir__))

RSpec.describe "Peer exchanges" do
  let(:store) { Samagotchi::PeerExchanges }
  let(:dir) { Dir.mktmpdir("peer-exchanges") }
  let(:id) { "abc12345" }

  after { FileUtils.remove_entry(dir) }

  def entry(t, at, **fields)
    { "t" => t, "at" => "2026-01-01T00:00:#{format("%02d", at)}Z" }.merge(fields.transform_keys(&:to_s))
  end

  it "appends private JSONL lines and ignores a torn line and a missing file" do
    expect(store.read(id, state_dir: dir)).to eq([])
    store.append(id, { t: "sent", peer: "claude", id: "s-a" }, state_dir: dir)
    path = File.join(dir, id, "peer_exchanges.jsonl")
    File.open(path, "a") { |f| f.write('{"t":') }
    expect(store.read(id, state_dir: dir)).to match([include("t" => "sent", "peer" => "claude", "at" => a_kind_of(String))])
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "joins by time, re and old skills, preserving unclaimed answers and failures" do
    lines = [
      entry("sent", 1, id: "s-a", kind: "validate", title: "first", by: "model"),
      entry("answer", 2, re: "s-a", summary: "VERDICT OK", serial: 1),
      entry("sent", 3, id: "s-a", kind: "validate", title: "resend", by: "user"),
      entry("sent", 4, id: "s-b", kind: "context", title: "context", by: "model"),
      entry("answer", 5, summary: "VERDICT CHANGES", serial: 2),
      entry("answer", 6, re: "s-b", summary: "VERDICT UNSURE", serial: 3),
      entry("answer", 7, re: "unknown", summary: "orphan", serial: 4),
      entry("send_failed", 8, id: "s-c", kind: "question", title: "failed", error: "offline")
    ]
    rows = store.joined(lines)
    expect(rows.map { |r| r[:state] }).to eq(%w[failed answered answered answered answered])
    expect(rows[1]).to include(id: nil, answer: include(summary: "orphan", serial: 4))
    expect(rows[2]).to include(id: "s-b", answer: include(verdict: "UNSURE"))
    expect(rows[3]).to include(title: "resend", by: "user", answer: include(serial: 2, verdict: "CHANGES"))
    expect(rows[4]).to include(title: "first", answer: include(serial: 1, verdict: "OK"))
    expect(store.joined(lines, last: 2).size).to eq(2)
    expect(store.joined([lines[3]]).first).to include(state: "none_expected")
  end

  it "does not join an answer to a later send, even when the file is out of order" do
    rows = store.joined([entry("sent", 4, id: "s-a", kind: "question"),
                         entry("answer", 2, re: "s-a", summary: "early")])
    expect(rows.map { |row| row[:state] }).to eq(%w[waiting answered])
  end
end
