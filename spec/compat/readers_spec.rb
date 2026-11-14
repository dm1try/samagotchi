# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bridge/card_store"
require "samagotchi/bridge/pending_card"
require "samagotchi/bridge/turn_drawings"
require "samagotchi/chi_home"
require "samagotchi/child_move"
require "samagotchi/context_sources"
require "samagotchi/continue_intent"
require "samagotchi/grants"
require "samagotchi/guardrails"
require "samagotchi/memory_bundle/installed_bundle"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/objectives_check"
require "samagotchi/objectives_track"
require "samagotchi/participants"
require "samagotchi/recap_store"
require "samagotchi/reminder_carry"
require "samagotchi/reminder_store"
require "samagotchi/session_continue"
require "samagotchi/session_stores"
require "samagotchi/schedules"
require "samagotchi/session"
require "samagotchi/session_inbox"
require "samagotchi/thinking_tails"
require "samagotchi/tools/delegate_cursor"
require "samagotchi/archive_store"
require "samagotchi/web/message_display"
require "samagotchi/worker_sidecar"
require_relative "../../script/release/release_tools"

RSpec.describe "the recorded compatibility corpus" do
  let(:compat_root) { File.join(__dir__) }
  # The last release whose corpus has no live-session files (input, note,
  # continue intent, stop marker) and no install journal: a later one must
  # hold them.
  let(:live_files_after) { Gem::Version.new("0.164.0") }
  let(:session_stores_after) { Gem::Version.new("0.168.0") }

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

  # @return [Boolean] whether +path+ holds a bare list, the format of 0.166.0 and before
  def approvals_list?(path)
    JSON.parse(File.read(path)).is_a?(Array)
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
    expect_install_journal_read(root, version, since)
    expect_store_files_read(sessions_dir, session_dir, version, since)
    expect_session_stores_read(root, sessions_dir, session_dir, version)
    expect_home_read(root, version, since)
  end

  # The chi home (home.json) every chi launch reads, whichever chi wrote it.
  def expect_home_read(root, version, since)
    path = File.join(root, Samagotchi::ChiHome::FILE)
    return unless recorded?(path, version, since)

    expect(Samagotchi::ChiHome.read(path: path))
      .to eq(Samagotchi::ChiHome::Record.new(ruby: "/compat-fixture/ruby/bin/ruby", gem_home: "/compat-fixture/gems",
                                             gem_path: "/compat-fixture/gems", mise: "/compat-fixture/bin/mise",
                                             set_at: "2026-01-01T00:00:00Z", set_by_version: version))
  end

  # An ask for +command+ under +rule+ in the corpus session, as the gate
  # makes it (Guardrails::Targets).
  def compat_ask(command, rule)
    call = { name: "execute", content: command }
    context = Samagotchi::Guardrails::Context.new(cwd: "/compat-fixture", session_id: "compat-session")
    verdict = Samagotchi::Guardrails::Verdict.new(call: call).ask!("compatibility corpus", rule: rule, source: "config")
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(call, context)
    verdict
  end

  # The stores another chi version shares with this one: an interrupted
  # continue's move.json, a continue's left.json, stored approvals, and a
  # participant's grant with its sidecar.
  def expect_store_files_read(sessions_dir, session_dir, version, since)
    move_path = File.join(session_dir, Samagotchi::ChildMove::INTENT_FILE)
    if recorded?(move_path, version, since)
      expect(Samagotchi::ChildMove.read_intent("compat-session", state_dir: sessions_dir))
        .to eq(Samagotchi::ChildMove::Intent.new(from: "compat-drawn", ids: ReleaseTools::COMPAT_CHILD_IDS,
                                                 noted: ["compat-child"]))
    end

    context = Samagotchi::ContextSources.session_location("compat-session", state_dir: sessions_dir)
    if recorded?(File.join(context.dir, Samagotchi::ContextSources::LEFT_FILE), version, since)
      expect(context.left).to eq([Samagotchi::ContextSources::Left.new(name: "claude-inbox", hint: "compatibility corpus",
                                                                       from: "compat-drawn")])
    end

    approvals_dir = Samagotchi::Guardrails::Approvals.dir_for(sessions_dir)
    approvals_path = File.join(approvals_dir, Samagotchi::Guardrails::Approvals::FILE)
    # 0.165.0 and 0.166.0 wrote a list: chi no longer reads it (see below).
    if recorded?(approvals_path, version, since) && !approvals_list?(approvals_path)
      warnings = []
      approvals = Samagotchi::Guardrails::Approvals.new(dir: approvals_dir, warn: ->(msg) { warnings << msg })
      expect(approvals.entries.map { |entry| entry["scope"] }).to eq(%w[session rule])
      expect(approvals.match(compat_ask("git push  origin main", "git-push"))).to include("scope" => "session")
      expect(approvals.match(compat_ask("git push origin other", "git-push"))).to be_nil
      expect(approvals.match(compat_ask("rm -rf dist", "rm-recursive"))).to include("scope" => "rule")
      expect(warnings).to be_empty
    end

    grants_path = Samagotchi::Grants.path(state_dir: sessions_dir)
    return unless recorded?(grants_path, version, since)

    grant = Samagotchi::Grants.new(grants_path, clock: -> { Time.utc(2026, 1, 2) }).lookup(ReleaseTools::COMPAT_GRANT_TOKEN)
    # An older chi's kind ("agent", "human") is a key this chi doesn't know:
    # kept as it was (Grant#extra), never read.
    expect(grant).to have_attributes(id: ReleaseTools::COMPAT_GRANT_ID, session_id: "compat-session",
                                     name: "Compat", identity: "compat@example.com", mode: "pair", spend_cap: 2.0,
                                     expires_at: "2026-01-08T00:00:00Z")
    expect(grant.extra).to eq({})
    expect(grant.state(Time.utc(2026, 1, 2))).to eq(:active)
    expect(Samagotchi::Participants.read("compat-session", state_dir: sessions_dir))
      .to match([have_attributes(id: ReleaseTools::COMPAT_GRANT_ID, name: "Compat", mode: "pair", cap: 2.0,
                                 expires_at: "2026-01-08T00:00:00Z", removed_at: nil)])
  end

  def expect_session_stores_read(root, sessions_dir, session_dir, version)
    Samagotchi::SessionStores.corpus_stores.each do |store|
      next if store.corpus_exception?

      path = File.join(root, store.corpus_dir, store.file)
      next unless recorded?(path, version, session_stores_after)

      case store.file
      when "archived"
        expect(Samagotchi::ArchiveStore.read(session_dir)).to include("archived_at" => "2026-01-01T00:00:00Z")
      when "pending_card.json"
        expect(Samagotchi::Bridge::PendingCard.read(session_dir)).to eq(id: "compat-card", bundle: "check-in")
      when "objectives_cards.json"
        expect(Samagotchi::Objectives.card_state(session_dir, "compat-proposal")).to eq("applied")
      when "objective_checks.jsonl"
        expect(Samagotchi::ObjectivesCheck.latest(session_dir, now: Time.utc(2026, 1, 1, 0, 1))["O1"])
          .to include("verdict" => "confirmed", "reason" => "recorded")
      when "objective_tracks.jsonl"
        settled, running = Samagotchi::ObjectivesTrack.latest(session_dir)
        expect(settled).to include("id" => "compat-track", "readings" => { "O1" => { "reading" => "progress",
                                                                                     "reason" => "compatibility corpus" } })
        expect(running).to be_nil
      when "reminders.json"
        entries = Samagotchi::ReminderCarry.take(session_dir, session_id: "compat-session",
                                                                        wall: Time.utc(2026, 1, 1, 0, 1))
        store = Samagotchi::ReminderStore.new
        expect(store.restore(entries, wall: Time.utc(2026, 1, 1, 0, 1))).to eq(["compatibility"])
        expect(store.reminders.values.first).to include(id: "compat-reminder", description: "compatibility corpus")
      when "recap.json"
        expect(Samagotchi::RecapStore.read(session_dir)).to include(text: "The user was testing compatibility.",
                                                                    title: "Compatibility")
      when "parent.json"
        expect(Samagotchi::Session.parent_override("compat-session", state_dir: sessions_dir)).to eq("compat-parent")
      when "thinking_tails.jsonl"
        expect(Samagotchi::ThinkingTails.read(session_dir)).to include(a_hash_including("turn_id" => "compat-tail-turn",
                                                                                        "tail" => "compatibility thinking"))
      when "delegates.json"
        cursor = Samagotchi::Tools::DelegateCursors.get("compat-session", "compat-child", state_dir: sessions_dir)
        expect(cursor).to have_attributes(reply_file: "output/compat-child.json", question_id: "compat-question")
      else
        # bridge, cards, drawings, move, continue, participants and stopped
        # have their existing dedicated readers above.
        expect(File.file?(path)).to be(true), "no compatibility reader for #{store.owner} (#{store.file})"
      end
    end
  end

  # An install journal (pending.json) beside the bundle record: what the
  # next install, maybe another chi's, reads.
  def expect_install_journal_read(root, version, since)
    journal = File.join(root, ".bundles", "compat", "pending.json")
    return unless recorded?(journal, version, since)

    Dir.mktmpdir("chi-compat-journal-") do |home|
      with_config_home(home) do
        provenance = Samagotchi::MemoryBundle::Provenance.new(name: "compat")
        FileUtils.mkdir_p(provenance.bundle_dir)
        FileUtils.cp(journal, provenance.pending_path)
        expect(provenance.pending_scope).to eq("system")
        expect(provenance.pending_shas("compat.md", target_dir: "/compat-fixture/memories")).to eq(["sha256:compat"])
      end
    end
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

    # A copy: a reader may rewrite or move what it reads, and the corpus
    # stays as recorded.
    Dir.mktmpdir("chi-compat-read-") do |tmp|
      FileUtils.cp_r(File.join(compat_root, version), tmp)
      expect_corpus_read(File.join(tmp, version), version, since: live_files_after)
    end
  end

  # 0.165.0 and 0.166.0 wrote approvals.json as a list; chi reads those
  # entries and converts the file to the versioned format on its next write.
  %w[0.165.0 0.166.0].each do |list_version|
    it "reads #{list_version}'s approvals list without setting it aside" do
      recorded = File.join(compat_root, list_version, "guardrails", Samagotchi::Guardrails::Approvals::FILE)
      Dir.mktmpdir("chi-compat-approvals-") do |dir|
        FileUtils.cp(recorded, File.join(dir, Samagotchi::Guardrails::Approvals::FILE))
        warnings = []
        approvals = Samagotchi::Guardrails::Approvals.new(dir: dir, warn: ->(msg) { warnings << msg })
        expect(approvals.entries).to eq(JSON.parse(File.read(recorded)))
        expect(warnings).to be_empty
        expect(Dir[File.join(dir, "#{Samagotchi::Guardrails::Approvals::FILE}.corrupt-*")]).to be_empty
      end
    end
  end

  it "reads every file the corpus writer records now (the next release's corpus)" do
    Dir.mktmpdir("chi-compat-now-") do |tmp|
      # Private: only release:bump records a corpus in the repository.
      root = ReleaseTools.send(:write_compat_corpus!, tmp, Samagotchi::VERSION)
      expect_corpus_read(root, Samagotchi::VERSION, since: Gem::Version.new("0"))
    end
  end
end
