# frozen_string_literal: true

require "tmpdir"
require "samagotchi/recap_store"
require "samagotchi/session"

RSpec.describe Samagotchi::RecapStore do
  let(:state_dir) { Dir.mktmpdir }
  let(:session_id) { "s-1" }
  let(:store) { described_class.new(session_id_lookup: -> { session_id }, state_dir_lookup: -> { state_dir }) }
  let(:state) { { text: "We set up Bluefin.", covered: 4, covered_digest: "abc", model: "main:ornith", created_at: "2026-09-24T10:00:00Z" } }
  let(:path) { File.join(state_dir, session_id, "recap.json") }

  after { FileUtils.rm_rf(state_dir) }

  def save_session_file = File.write(File.join(state_dir, "#{session_id}.json"), "{}")

  it "saves the recap next to the session's notes and images, and loads it back" do
    save_session_file
    store.save(state)
    expect(JSON.parse(File.read(path))).to include("text" => "We set up Bluefin.", "covered" => 4, "covered_digest" => "abc")
    expect(store.load).to eq(state)
    expect(Dir.glob("#{path}*")).to eq([path]) # no temp file left
  end

  it "keys by the current session" do
    expect(store.key).to eq("s-1")
  end

  it "writes nothing for a session that no longer exists (deleted or discarded)" do
    store.save(state)
    expect(File.exist?(path)).to be false
    expect(Dir.exist?(File.dirname(path))).to be false
  end

  it "loads nothing when there is no file, or it is unreadable" do
    expect(store.load).to be_nil
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{not json")
    expect(store.load).to be_nil
    File.write(path, JSON.generate(text: "", covered: 2))
    expect(store.load).to be_nil
  end

  it "reads a session dir's recap without a store (for the web and previews)" do
    save_session_file
    store.save(state)
    expect(described_class.read(File.join(state_dir, session_id))).to eq(state)
    expect(described_class.read(File.join(state_dir, "missing"))).to be_nil
  end

  it "saves nothing and loads nothing with no current session" do
    none = described_class.new(session_id_lookup: -> { nil }, state_dir_lookup: -> { state_dir })
    expect { none.save(state) }.not_to raise_error
    expect(none.load).to be_nil
  end
end
