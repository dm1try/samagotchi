# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/participant_uploads"
require "samagotchi/grants"

RSpec.describe Samagotchi::ParticipantUploads do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir and example.run }
  end

  let(:dir) { @dir }
  let(:file) { "images/0123456789abcdef.png" }
  let(:path) { File.join(dir, described_class::FILE) }

  it "starts empty: nothing owned, nothing counted" do
    expect(described_class.count(dir, "p_aaaaaaaa")).to eq(0)
    expect(described_class.attempts(dir, "p_aaaaaaaa")).to eq(0)
    expect(described_class.owned?(dir, file, "p_aaaaaaaa")).to be(false)
    expect(File.exist?(path)).to be(false)
  end

  it "records a grant's upload once, counts distinct files and attempts per grant" do
    expect(described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")).to be(true)
    expect(described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")).to be(false)
    described_class.add(dir, file: "images/fedcba9876543210.jpg", grant_id: "p_aaaaaaaa")
    3.times { described_class.attempt!(dir, "p_aaaaaaaa") }
    described_class.attempt!(dir, "p_bbbbbbbb")

    expect(described_class.count(dir, "p_aaaaaaaa")).to eq(2)
    expect(described_class.count(dir, "p_bbbbbbbb")).to eq(0)
    expect(described_class.attempts(dir, "p_aaaaaaaa")).to eq(3)
    expect(described_class.attempts(dir, "p_bbbbbbbb")).to eq(1)
    expect(described_class.owned?(dir, file, "p_aaaaaaaa")).to be(true)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
  end

  it "answers count, attempts and ownership from one read (State), and writes from the state it is given" do
    described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")
    described_class.attempt!(dir, "p_aaaaaaaa")
    state = described_class.read(dir)
    expect([state.count("p_aaaaaaaa"), state.attempts_of("p_aaaaaaaa"), state.owned?(file, "p_aaaaaaaa")]).to eq([1, 1, true])
    described_class.attempt!(dir, "p_aaaaaaaa", state: state)
    described_class.add(dir, file: "images/fedcba9876543210.png", grant_id: "p_aaaaaaaa", state: described_class.read(dir))
    expect(described_class.read(dir).attempts_of("p_aaaaaaaa")).to eq(2)
    expect(described_class.count(dir, "p_aaaaaaaa")).to eq(2)
  end

  it "keys ownership by (file, grant): the same bytes uploaded by two grants are each one's, never shared" do
    described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")
    expect(described_class.owned?(dir, file, "p_bbbbbbbb")).to be(false)
    described_class.add(dir, file: file, grant_id: "p_bbbbbbbb")
    expect(described_class.owned?(dir, file, "p_bbbbbbbb")).to be(true)
    expect(described_class.count(dir, "p_aaaaaaaa")).to eq(1)
    expect(described_class.count(dir, "p_bbbbbbbb")).to eq(1)
  end

  it "rewrites the file whole (no temporary left behind)" do
    described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")
    described_class.attempt!(dir, "p_aaaaaaaa")
    expect(Dir.children(dir)).to eq([described_class::FILE])
    data = JSON.parse(File.read(path))
    expect(data["images"].map { |h| h.slice("file", "grant_id") }).to eq([{ "file" => file, "grant_id" => "p_aaaaaaaa" }])
    expect(data["attempts"]).to eq({ "p_aaaaaaaa" => 1 })
  end

  [["not JSON", "{oops"], ["not an object", "[1]"], ["an entry without a file", '{"images":[{"grant_id":"p_aaaaaaaa"}]}'],
   ["an entry that isn't an object", '{"images":["x"]}'], ["attempts not an object", '{"attempts":[1]}']].each do |what, body|
    it "fails closed on a record that doesn't read (#{what}): at quota, owns nothing, left as it was, logged" do
      File.write(path, body)
      warned = []
      allow(Samagotchi::Log).to receive(:warn) { |*args, **kw| warned << [args, kw] }
      expect(described_class.count(dir, "p_aaaaaaaa")).to be >= Samagotchi::Grants::MAX_IMAGES
      expect(described_class.attempts(dir, "p_aaaaaaaa")).to be >= Samagotchi::Grants::MAX_IMAGE_ATTEMPTS
      expect(described_class.owned?(dir, file, "p_aaaaaaaa")).to be(false)
      expect(described_class.add(dir, file: file, grant_id: "p_aaaaaaaa")).to be(false)
      described_class.attempt!(dir, "p_aaaaaaaa")
      expect(File.read(path)).to eq(body)
      expect(warned.map { |args, _| args }).to all(eq([:web, "participant_images_unreadable"]))
    end
  end
end
