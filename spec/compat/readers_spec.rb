# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bridge/card_store"
require "samagotchi/bridge/turn_drawings"
require "samagotchi/continue_intent"
require "samagotchi/memory_bundle/installed_bundle"
require "samagotchi/schedules"
require "samagotchi/session"
require "samagotchi/session_inbox"
require "samagotchi/web/message_display"
require "samagotchi/worker_sidecar"
require_relative "../../script/release/release_tools"

RSpec.describe "the recorded compatibility corpus" do
  let(:compat_root) { File.join(__dir__) }
  # The last release whose corpus has no live-session files (input, note,
  # continue intent, stop marker): a later one must hold them.
  let(:live_files_after) { Gem::Version.new("0.164.0") }

  def corpus_version
    versions = Dir.children(compat_root).select do |name|
      path = File.join(compat_root, name)
      File.directory?(path) && Gem::Version.correct?(name)
    end
    current = Gem::Version.new(Samagotchi::VERSION)
    previous = versions.select { |version| Gem::Version.new(version) < current }
    candidates = previous.empty? ? versions.select { |version| Gem::Version.new(version) <= current } : previous
    candidates.max_by { |version| Gem::Version.new(version) }
  end

  # chi web's show of +id+ draws every turn of its from a line
  # (Bridge::TurnDrawings.cover, then MessageDisplay's stamps).
  # @return [Array<Bridge::TurnDrawings::Line>] the lines
  def expect_every_turn_drawn(sessions_dir, id)
    session = Samagotchi::Session.load(id, state_dir: sessions_dir)
    dir = Samagotchi::Session.session_dir(id, state_dir: sessions_dir)
    lines = Samagotchi::Bridge::TurnDrawings.cover(Samagotchi::Bridge::TurnDrawings.read(dir), session.messages,
                                                   entries: Samagotchi::Bridge::CardStore.saved(dir, messages: session.messages))
    host = Class.new do
      include Samagotchi::Web::MessageDisplay

      public :messages_for_display
    end.new
    items = host.messages_for_display(session.messages, markdown: false, drawings: lines)
    expect(items).not_to be_empty
    expect(items.map { |item| item[:drawn] }).to all(be_a(String)), "#{id}: #{items.inspect}"
    lines
  end

  # Whether +version+'s corpus holds +path+: a corpus from before the file
  # was recorded may not (skipped), a later one must.
  def recorded?(path, version, after)
    return true if File.exist?(path)

    expect(Gem::Version.new(version)).to be <= after, "#{version}'s corpus has no #{path}"
    false
  end

  # Every file of the corpus at +root+ (recorded by +version+), read by
  # today's readers. +since+: the newest version allowed to lack the
  # live-session files.
  def expect_corpus_read(root, version, since:)
    sessions_dir = File.join(root, "sessions")
    session = Samagotchi::Session.load("compat-session", state_dir: sessions_dir)
    expect(session).to have_attributes(id: "compat-session", model_name: "compat:model")
    expect(session.messages.map { |message| message[:content] }).to eq(["compatibility corpus"])

    session_dir = Samagotchi::Session.session_dir(session.id, state_dir: sessions_dir)
    expect(Samagotchi::WorkerSidecar.read(session_dir))
      .to have_attributes(session_id: session.id, version: version, port: 4321)
    expect(Samagotchi::Bridge::CardStore.saved(session_dir).map { |entry| entry.slice(:type, :hook, :text) })
      .to eq([{ type: :hook_notice, hook: "compat", text: "compatibility corpus" }])

    schedule = Samagotchi::Schedules.new(state_dir: sessions_dir).entries.fetch(0)
    expect(schedule).to have_attributes(id: "compat-schedule", anchor: session.id, prompt: "compatibility corpus")
    expect(schedule.recurrence).to eq(kind: "every", interval: "1h")

    expect_every_turn_drawn(sessions_dir, "compat-session")
    # Recorded since chi drew a sample's turn (0.162): its live line, not one made from its messages.
    if Samagotchi::Session.exist?("compat-drawn", state_dir: sessions_dir)
      lines = expect_every_turn_drawn(sessions_dir, "compat-drawn")
      expect(lines.map { |line| [line.turn_id, line.end["record_id"]] }).to eq([["compat-turn", nil]])
    end

    manifest_path = File.join(root, ".bundles", "compat", "manifest.json")
    record = Samagotchi::MemoryBundle::InstalledBundle.read("compat", manifest_path)
    expect(record).to have_attributes(name: "compat", version: version, scope: "system", source: "compat-fixture")

    expect_live_files_read(sessions_dir, session_dir, version, since)
  end

  # The files other chi versions write into a live session's folder.
  def expect_live_files_read(sessions_dir, session_dir, version, since)
    input_dir = File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR)
    if recorded?(input_dir, version, since)
      inputs = Samagotchi::SessionInbox.find_new_input_files(session_dir)
      expect(inputs.size).to eq(1)
      input = Samagotchi::SessionInbox.read_input(inputs.first)
      expect(input).to have_attributes(prompt: "compatibility corpus", delivery: "queue",
                                       images: [{ file: "compat.png", name: "compat.png" }])
      expect(input.origin).to have_attributes(client_id: "web:compat", enqueued_id: ReleaseTools::COMPAT_ENQUEUED_ID,
                                              author: "p:compat")
      expect(Samagotchi::SessionInbox.waits_for_turn_end?(inputs.first)).to be(true)
    end

    notes_dir = File.join(session_dir, Samagotchi::SessionInbox::NOTES_DIR)
    if recorded?(notes_dir, version, since)
      notes = Samagotchi::SessionInbox.find_new_note_files(session_dir).map { |file| Samagotchi::SessionInbox.read_note(file) }
      expect(notes).to match([a_hash_including(text: "compatibility corpus", source: "cli", from_session: "compat-drawn",
                                               from_cwd: "/compat-fixture", created_at: "2026-01-01T00:00:00Z")])
    end

    intent_path = File.join(session_dir, Samagotchi::ContinueIntent::FILE)
    if recorded?(intent_path, version, since)
      expect(Samagotchi::ContinueIntent.read(intent_path))
        .to eq(Samagotchi::ContinueIntent::Intent.new(successor_id: "compat-successor", previously_archived: ["compat-drawn"],
                                                      archived_ids: ["compat-session"]))
    end

    stopped_path = File.join(session_dir, Samagotchi::Session::STOPPED_FILE)
    return unless recorded?(stopped_path, version, since)

    expect(Samagotchi::Session.stopped_at("compat-session", state_dir: sessions_dir)).to eq(Time.utc(2026, 1, 1))
    expect(Samagotchi::Session.load("compat-session", state_dir: sessions_dir).status).to eq(Samagotchi::Session::STATUS_STOPPED)
  end

  it "reads the newest previous-release samples with today's state readers" do
    version = corpus_version
    expect(version).not_to be_nil, "record a compatibility corpus with release:bump"

    expect_corpus_read(File.join(compat_root, version), version, since: live_files_after)
  end

  it "reads every file the corpus writer records now (the next release's corpus)" do
    Dir.mktmpdir("chi-compat-now-") do |tmp|
      # Private: only release:bump records a corpus in the repository.
      root = ReleaseTools.send(:write_compat_corpus!, tmp, Samagotchi::VERSION)
      expect_corpus_read(root, Samagotchi::VERSION, since: Gem::Version.new("0"))
    end
  end
end
