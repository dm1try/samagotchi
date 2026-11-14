# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/participant_prompts"

RSpec.describe Samagotchi::ParticipantPrompts do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:dir) { @dir }
  let(:path) { File.join(dir, described_class::FILE) }
  let(:a) { "p_aaaaaaaa" }
  let(:b) { "p_bbbbbbbb" }

  def append(text, grant_id: a, live: [a, b])
    described_class.append(dir, grant_id: grant_id, text: text, live_grant_ids: live)
  end

  it "starts empty and writes nothing until an append" do
    expect(described_class.entries(dir, a)).to eq([])
    expect(File.exist?(path)).to be(false)
  end

  it "keeps each grant's prompts apart, oldest first, normalized, in a 0600 file" do
    expect(append("A-1")).to be(true)
    append("  A-2\r\nline two \n")
    append("B-1", grant_id: b)

    expect(described_class.entries(dir, a)).to eq(["A-1", "A-2\nline two"])
    expect(described_class.entries(dir, b)).to eq(["B-1"])
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "answers a new array: changing it changes nothing kept" do
    append("A-1")
    described_class.entries(dir, a) << "forged"
    expect(described_class.entries(dir, a)).to eq(["A-1"])
  end

  it "keeps the last LIMIT per grant" do
    (described_class::LIMIT + 5).times { |i| append("p#{i}") }
    list = described_class.entries(dir, a)
    expect(list.size).to eq(described_class::LIMIT)
    expect(list.first).to eq("p5")
    expect(list.last).to eq("p#{described_class::LIMIT + 4}")
  end

  it "records a text of MAX_ENTRY_BYTES and skips (never cuts) a longer one, and an empty one" do
    kept = "x" * described_class::MAX_ENTRY_BYTES
    expect(append(kept)).to be(true)
    expect(append("#{kept}y")).to be(false)
    expect(append("  \n ")).to be(false)
    expect(described_class.entries(dir, a)).to eq([kept])
  end

  it "drops on append the lists of grants not in live_grant_ids" do
    append("B-1", grant_id: b)
    append("A-1", live: [a])
    expect(described_class.entries(dir, b)).to eq([])
    expect(JSON.parse(File.read(path))["prompts"].keys).to eq([a])
  end

  it "keeps the appending grant's list even when the caller's live ids miss it" do
    append("A-1", live: [])
    expect(described_class.entries(dir, a)).to eq(["A-1"])
  end

  it "refuses a grant id that isn't a grant's (p_<8 hex>): never a key" do
    ["p:#{a}", "owner", "../x", "", nil, 7, "p_AAAAAAAA"].each do |id|
      expect(described_class.append(dir, grant_id: id, text: "x", live_grant_ids: [id])).to be(false)
      expect(described_class.entries(dir, id)).to eq([])
    end
    expect(File.exist?(path)).to be(false)
  end

  context "with a broken file" do
    let(:warned) { [] }

    before { allow(Samagotchi::Log).to receive(:warn) { |*args, **kw| warned << [args, kw] } }

    ['{"prompts": ', '["a"]', '{"prompts": ["a"]}', '{"prompts": "x"}'].each do |body|
      it "reads no entries, logs, and leaves #{body.inspect} byte for byte on append" do
        File.write(path, body)
        expect(described_class.entries(dir, a)).to eq([])
        expect(append("A-1")).to be(false)
        expect(File.read(path)).to eq(body)
        expect(warned.map { |args, _| args[1] }).to include("participant_prompts_unreadable")
      end
    end
  end

  it "keeps only String entries of a hand-edited list, and reads a non-list as none, without raising" do
    File.write(path, JSON.generate(prompts: { a => [1, {}, "ok", nil, ["x"]], b => "nope", "junk" => ["z"] }))
    expect(described_class.entries(dir, a)).to eq(["ok"])
    expect(described_class.entries(dir, b)).to eq([])

    append("A-2")
    expect(JSON.parse(File.read(path))["prompts"]).to eq(a => %w[ok A-2], b => [])
  end
end
