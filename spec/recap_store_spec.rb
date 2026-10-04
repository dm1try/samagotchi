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

  it "deletes the saved recap (one that no longer describes the history)" do
    save_session_file
    store.save(state)
    store.delete
    expect(File.exist?(path)).to be false
    expect(store.load).to be_nil
    expect { store.delete }.not_to raise_error
  end

  it "reads a session dir's recap without a store (for the web and previews)" do
    save_session_file
    store.save(state)
    expect(described_class.read(File.join(state_dir, session_id))).to eq(state)
    expect(described_class.read(File.join(state_dir, "missing"))).to be_nil
  end

  it "saves nothing and loads nothing with no current session" do
    none = described_class.new(session_id_lookup: -> {}, state_dir_lookup: -> { state_dir })
    expect { none.save(state) }.not_to raise_error
    expect(none.load).to be_nil
  end

  describe ".preview" do
    def write(text)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(text: text, covered: 2))
    end

    it "is the saved recap's first sentence, on one line" do
      write("The user set up Bluefin,\nits CI. The assistant wrote the README.")
      expect(described_class.preview(File.dirname(path))).to eq("The user set up Bluefin, its CI.")
    end

    it "cuts a long one" do
      write("word " * 60)
      expect(described_class.preview(File.dirname(path)).length).to eq(described_class::PREVIEW_CHARS)
      expect(described_class.preview(File.dirname(path))).to end_with("…")
    end

    # Openings from the recap-length S0 spike (Ornith 35B-A3B)
    it "drops the leading subject phrase, so the line starts with the task" do
      {
        "The user was testing how the web frontend renders markdown, feeding it a showcase." =>
          "Testing how the web frontend renders markdown, feeding it a showcase.",
        "The user was working through an architecture investigation of the Samagotchi project." =>
          "Working through an architecture investigation of the Samagotchi project.",
        "The user is checking how the parser handles tabs." => "Checking how the parser handles tabs.",
        "The user and assistant were exploring how the Samagotchi agent could be open-sourced." =>
          "Exploring how the Samagotchi agent could be open-sourced.",
        "The user and the assistant were getting familiar with the tools." => "Getting familiar with the tools."
      }.each do |recap, line|
        write("#{recap} The assistant wrote the README.")
        expect(described_class.preview(File.dirname(path))).to eq(line)
      end
    end

    it "drops the subject before a past-tense verb too" do
      {
        "The user and assistant explored open-sourcing samagotchi." => "Explored open-sourcing samagotchi.",
        "The user and the assistant discussed the recap length." => "Discussed the recap length.",
        "The user checked the current time and asked the assistant to list its tools." =>
          "Checked the current time and asked the assistant to list its tools.",
        "The user tried a new prompt." => "Tried a new prompt.",
        "The user shared a screenshot of the web page." => "Shared a screenshot of the web page."
      }.each do |recap, line|
        write(recap)
        expect(described_class.preview(File.dirname(path))).to eq(line)
      end
    end

    it "keeps openings that are not a subject plus an -ing or an -ed verb" do
      [
        "The user asked the assistant to review what's stored in its memory library.",
        "The user wanted a shorter recap.",
        "The user requested a list of tools.",
        "The user needed the build to pass.",
        "The user hoped to ship it today.",
        "The user preferred the dark theme.",
        "The user expected a single sentence.",
        "The user seemed happy with it.",
        "The user ran the suite twice.",
        "The user was curious about the recap.",
        "The user and assistant's red-team exercise was paused.",
        "Bluefin's CI was set up; the user was testing it."
      ].each do |recap|
        write(recap)
        expect(described_class.preview(File.dirname(path))).to eq(recap)
      end
    end

    it "cuts after dropping the subject phrase, so the task gets the room" do
      write("The user was testing #{"word " * 40}")
      line = described_class.preview(File.dirname(path))
      expect(line).to start_with("Testing word")
      expect(line.length).to eq(described_class::PREVIEW_CHARS)
    end

    it "is nil without a recap" do
      expect(described_class.preview(File.dirname(path))).to be_nil
    end
  end
end
