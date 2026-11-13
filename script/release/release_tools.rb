# frozen_string_literal: true

require "open3"
require "prism"
require "json"
require "fileutils"
require "tmpdir"
require "yaml"
require_relative "../../lib/samagotchi/memory_bundle/shas"
require_relative "compat_wire"

# The logic behind the Rakefile's `bundles:` and `release:` tasks, kept out of
# lib/ (it isn't shipped) and free of Rake so the specs can call it. Every
# method takes the repository root, so a spec can point it at a temp copy.
# See docs/releasing.md for how the tasks fit together.
module ReleaseTools
  REPO_URL = "https://github.com/dm1try/samagotchi"
  BUNDLES_DIR = "lib/samagotchi/bundles"
  VERSION_FILE = "lib/samagotchi/version.rb"
  SYSTEM_BUNDLE = "system"
  SYSTEM_MANIFEST = "#{BUNDLES_DIR}/#{SYSTEM_BUNDLE}/manifest.yml".freeze
  CHANGELOG = "CHANGELOG.md"
  VERSION_PATTERN = /\A\d+\.\d+\.\d+(?:\.[0-9A-Za-z.]+)?\z/
  COMPAT_SESSION_ID = "compat-session"
  # A session whose one turn a Bridge drew (turn_drawings.jsonl); the other
  # has none (a turn from before drawings).
  COMPAT_DRAWN_ID = "compat-drawn"
  COMPAT_STAMP = "2026-01-01T00:00:00Z"
  # The queued input's ids, and the successor a continue intent names.
  COMPAT_ENQUEUED_ID = "00000000-0000-4000-8000-000000000001"
  COMPAT_SUCCESSOR_ID = "compat-successor"
  # The children an interrupted continue's move.json names (the first
  # already noted), and a participant's grant: its id and the token whose
  # digest the store keeps.
  COMPAT_CHILD_IDS = %w[compat-child compat-child-2].freeze
  COMPAT_GRANT_ID = "p_c0ffee00"
  COMPAT_GRANT_TOKEN = "chp_compatibility-corpus"

  class Error < StandardError; end

  module_function

  # --- versions ---------------------------------------------------------

  def gem_version(root)
    File.read(File.join(root, VERSION_FILE))[/VERSION = "([^"]+)"/, 1] or raise Error, "no VERSION in #{VERSION_FILE}"
  end

  # A release's small canonical files, produced through the current readers'
  # corresponding writers. The corpus root is isolated from user state.
  def write_compat_corpus!(root, version)
    raise Error, "#{version.inspect} isn't a version (x.y.z)" unless version.match?(VERSION_PATTERN)

    corpus_dir = File.join(root, "spec", "compat", version)
    raise Error, "compatibility corpus already exists for #{version}" if File.exist?(corpus_dir)

    require_relative "../../lib/samagotchi/session"
    require_relative "../../lib/samagotchi/worker_link"
    require_relative "../../lib/samagotchi/worker_sidecar"
    require_relative "../../lib/samagotchi/bridge/card_store"
    require_relative "../../lib/samagotchi/bridge/turn_accumulator"
    require_relative "../../lib/samagotchi/bridge/turn_drawings"
    require_relative "../../lib/samagotchi/schedules"
    require_relative "../../lib/samagotchi/memory_bundle/provenance"
    require_relative "../../lib/samagotchi/session_inbox"
    require_relative "../../lib/samagotchi/continue_intent"
    require_relative "../../lib/samagotchi/child_move"
    require_relative "../../lib/samagotchi/context_sources"
    require_relative "../../lib/samagotchi/guardrails"
    require_relative "../../lib/samagotchi/grants"
    require_relative "../../lib/samagotchi/participants"
    require_relative "../../lib/samagotchi/chi_home"
    require_relative "../../lib/samagotchi/session_stores"
    require_relative "../../lib/samagotchi/bridge/pending_card"
    require_relative "../../lib/samagotchi/objectives_check"
    require_relative "../../lib/samagotchi/objectives_track"
    require_relative "../../lib/samagotchi/reminder_carry"
    require_relative "../../lib/samagotchi/reminder_store"
    require_relative "../../lib/samagotchi/recap_store"
    require_relative "../../lib/samagotchi/thinking_tails"
    require_relative "../../lib/samagotchi/tools/delegate_cursor"
    require_relative "../../lib/samagotchi/archive_store"

    Dir.mktmpdir("chi-compat-corpus-") do |tmp|
      staged = File.join(tmp, "corpus")
      sessions_dir = File.join(staged, "sessions")
      session_dir = File.join(sessions_dir, COMPAT_SESSION_ID)
      FileUtils.mkdir_p([sessions_dir, session_dir])

      isolated_env = %w[XDG_CONFIG_HOME XDG_STATE_HOME].to_h { |key| [key, ENV[key]] }
      ENV["XDG_CONFIG_HOME"] = File.join(tmp, "config")
      ENV["XDG_STATE_HOME"] = File.join(tmp, "state")
      begin
        at = Time.utc(2026, 1, 1)
        Samagotchi::Session.new(id: COMPAT_SESSION_ID, mode: "assist", model_name: "compat:model",
                                working_directory: "/compat-fixture", created_at: COMPAT_STAMP,
                                updated_at: COMPAT_STAMP, messages: [{ role: "user", content: "compatibility corpus" }])
                               .save(state_dir: sessions_dir, now: at)
        session_path = Samagotchi::Session.session_file(COMPAT_SESSION_ID, state_dir: sessions_dir)
        session_data = JSON.parse(File.read(session_path))
        session_data["written_by"] = version
        session_data["updated_at"] = COMPAT_STAMP
        File.write(session_path, "#{JSON.pretty_generate(session_data)}\n")

        Samagotchi::WorkerSidecar.new(port: 4321, bind: "127.0.0.1", session_id: COMPAT_SESSION_ID,
                                      started_at: COMPAT_STAMP, version: version, features: ["restart"],
                                      epoch: "compat-epoch", pid: 12_345, protocol: Samagotchi::WorkerLink::PROTOCOL)
                               .write(session_dir)
        Samagotchi::Bridge::CardStore.new(path: File.join(session_dir, Samagotchi::Bridge::CardStore::FILE))
                                     .call(type: :hook_notice, hook: "compat", text: "compatibility corpus",
                                           between_turns: true)

        drawn_path = write_compat_drawn_session!(sessions_dir, version, at)
        live_paths = write_compat_live_files!(sessions_dir, session_dir, at)
        store_paths = write_compat_store_files!(sessions_dir, at)
        wire_paths = write_compat_wire!(staged, version)

        schedules = Samagotchi::Schedules.new(state_dir: sessions_dir, clock: -> { at })
        schedules.add(target: COMPAT_SESSION_ID, prompt: "compatibility corpus", title: "Compatibility corpus",
                      recurrence: Samagotchi::Schedules.recurrence(every: "1h"), catch_up: "once", keep_links: 5,
                      max_failures: 3, max_skips: 12)
        schedules_data = JSON.parse(File.read(schedules.path))
        schedules_data["updated_at"] = COMPAT_STAMP
        schedules_data["schedules"].first["id"] = "compat-schedule"
        File.write(schedules.path, "#{JSON.pretty_generate(schedules_data)}\n")
        FileUtils.rm_f(schedules.lock_path)

        provenance = Samagotchi::MemoryBundle::Provenance.new(name: "compat")
        provenance.write(files: {}, scope: "system", version: version, source_path: "compat-fixture")
        manifest_path = File.join(provenance.bundle_dir, "manifest.json")
        manifest = JSON.parse(File.read(manifest_path))
        manifest["installed_at"] = COMPAT_STAMP
        File.write(manifest_path, "#{JSON.pretty_generate(manifest)}\n")
        bundle_record = File.join(staged, ".bundles", "compat", "manifest.json")
        FileUtils.mkdir_p(File.dirname(bundle_record))
        FileUtils.cp(manifest_path, bundle_record)
        # An install journal (an upgrade interrupted before its record):
        # the next run, maybe another chi's, reads its shas.
        provenance.write_pending(version: version, scope: "system", target_dir: "/compat-fixture/memories",
                                 files: { "compat.md" => "sha256:compat" })
        bundle_journal = File.join(File.dirname(bundle_record), "pending.json")
        FileUtils.cp(provenance.pending_path, bundle_journal)
        # The chi home every chi launch reads, whichever chi wrote it.
        home_path = File.join(staged, Samagotchi::ChiHome::FILE)
        Samagotchi::ChiHome.write!(Samagotchi::ChiHome::Record.new(ruby: "/compat-fixture/ruby/bin/ruby",
                                                                   gem_home: "/compat-fixture/gems",
                                                                   gem_path: "/compat-fixture/gems",
                                                                   mise: "/compat-fixture/bin/mise",
                                                                   set_at: COMPAT_STAMP, set_by_version: version),
                                   path: home_path)

        required = [
          session_path,
          File.join(session_dir, Samagotchi::WorkerSidecar::FILE),
          File.join(session_dir, Samagotchi::Bridge::CardStore::FILE),
          drawn_path,
          schedules.path,
          bundle_record,
          bundle_journal,
          home_path,
          *live_paths,
          *store_paths,
          *Samagotchi::SessionStores.corpus_stores.reject(&:corpus_exception?).map do |store|
            File.join(staged, store.corpus_dir, store.file)
          end,
          *wire_paths
        ]
        missing = required.reject { |path| File.file?(path) }
        raise Error, "compatibility corpus writer omitted #{missing.join(", ")}" unless missing.empty?
      ensure
        isolated_env.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
      end

      FileUtils.mkdir_p(File.dirname(corpus_dir))
      FileUtils.mv(staged, corpus_dir)
    end
    corpus_dir
  end
  private_class_method :write_compat_corpus!

  # What a worker answers its clients (CompatWire: /state, /snapshot idle
  # and mid-turn, /tail, and the session file it saved) in +staged+/wire/,
  # recorded twice: the two must be equal, so a field CompatWire.normalise
  # doesn't pin (a time, a random id) fails here, named by its JSON path.
  # @return [Array<String>] the files
  def write_compat_wire!(staged, version)
    Dir.mktmpdir("chi-compat-wire-check-") do |tmp|
      recordings = %w[first second].map do |name|
        File.join(tmp, name).tap { |dir| CompatWire.record!(dir, version: version) }
      end
      CompatWire::FILES.each do |name|
        path = CompatWire.first_difference(*recordings.map { |dir| JSON.parse(File.read(File.join(dir, name))) })
        raise Error, "compat wire: two recordings of wire/#{name} differ at #{path}: pin it in CompatWire.normalise" if path
      end
      FileUtils.cp_r(recordings.first, File.join(staged, "wire"))
    end
    CompatWire::FILES.map { |name| File.join(staged, "wire", name) }
  end
  private_class_method :write_compat_wire!

  # The files other chi versions write into a live session's folder, each by
  # its one writer: a queued input file (SessionInbox.write_input), a context
  # note (SessionInbox.write_note), a continue's intent (ContinueIntent.write)
  # and the stop marker (Session.mark_stopped). The starting marker isn't
  # among them: a recorded one is always stale, so no reader could tell it
  # from a broken one (StartingMarker; spec/worker_contract_spec.rb).
  # @return [Array<String>] the files
  def write_compat_live_files!(sessions_dir, session_dir, at)
    input = Samagotchi::SessionInbox.write_input(session_dir, prompt: "compatibility corpus", client_id: "web:compat",
                                                              enqueued_id: COMPAT_ENQUEUED_ID, delivery: "queue",
                                                              images: [{ file: "compat.png", name: "compat.png" }],
                                                              author: "p:compat", now: at)
    raise Error, "compatibility corpus: the input file wasn't written" unless input

    note = Samagotchi::SessionInbox.write_note(COMPAT_SESSION_ID, text: "compatibility corpus", source: "cli",
                                                                  from_session: COMPAT_DRAWN_ID, from_cwd: "/compat-fixture",
                                                                  state_dir: sessions_dir, now: at)
    intent = File.join(session_dir, Samagotchi::ContinueIntent::FILE)
    Samagotchi::ContinueIntent.write(intent, successor_id: COMPAT_SUCCESSOR_ID, previously_archived: [COMPAT_DRAWN_ID],
                                             archived_ids: [COMPAT_SESSION_ID])
    Samagotchi::Session.mark_stopped(COMPAT_SESSION_ID, state_dir: sessions_dir, now: at)
    [input, note, intent, File.join(session_dir, Samagotchi::Session::STOPPED_FILE)]
  end
  private_class_method :write_compat_live_files!

  # The stores other chi versions share with this one, each by its one
  # writer: an interrupted continue's move.json (ChildMove.write_intent, in
  # the new link's folder: here COMPAT_SESSION_ID's), what a continue left
  # with the previous link (ContextSources' left.json), stored approvals
  # (Guardrails::Approvals#add: a session's and a rule's) and a
  # participant's grant with its sidecar (Grants#issue, Participants'
  # participants.json). Random ids and times are pinned afterwards.
  # @return [Array<String>] the files
  def write_compat_store_files!(sessions_dir, at)
    move = Samagotchi::ChildMove::Intent.new(from: COMPAT_DRAWN_ID, ids: COMPAT_CHILD_IDS, noted: COMPAT_CHILD_IDS.first(1))
    Samagotchi::ChildMove.write_intent(COMPAT_SESSION_ID, move, state_dir: sessions_dir)
    move_path = File.join(Samagotchi::Session.session_dir(COMPAT_SESSION_ID, state_dir: sessions_dir),
                          Samagotchi::ChildMove::INTENT_FILE)

    context = Samagotchi::ContextSources.session_location(COMPAT_SESSION_ID, state_dir: sessions_dir)
    context.write_left([Samagotchi::ContextSources::Left.new(name: "claude-inbox", hint: "compatibility corpus",
                                                             from: COMPAT_DRAWN_ID)])

    session_dir = Samagotchi::Session.session_dir(COMPAT_SESSION_ID, state_dir: sessions_dir)
    [
      move_path,
      File.join(context.dir, Samagotchi::ContextSources::LEFT_FILE),
      write_compat_approvals!(sessions_dir),
      *write_compat_grant!(sessions_dir, at),
      write_compat_session_stores!(sessions_dir, session_dir, at)
    ].flatten
  end
  private_class_method :write_compat_store_files!

  # The remaining cross-version per-session stores use their real writers.
  # Nondeterministic timestamps and ids are pinned after writing, as above.
  # @return [Array<String>] the stores' paths
  def write_compat_session_stores!(sessions_dir, session_dir, at)
    session_id = COMPAT_SESSION_ID

    Samagotchi::ArchiveStore.archive(session_id, state_dir: sessions_dir)
    archive_path = File.join(session_dir, Samagotchi::ArchiveStore::FILE)
    normalize_json_store!(archive_path) { |data| data["archived_at"] = COMPAT_STAMP }

    Samagotchi::Bridge::PendingCard.new(session_dir).call(
      { type: :card, id: "compat-card", source: "check-in", actions: [{ label: "Nudge" }], in_turn: true }
    )
    pending_path = File.join(session_dir, Samagotchi::Bridge::PendingCard::FILE)

    Samagotchi::Objectives.with_lock(session_dir) do
      Samagotchi::Objectives.record_card(session_dir, "compat-proposal", Samagotchi::Objectives::APPLIED)
    end
    Samagotchi::ObjectivesCheck::STORE.write(session_dir, now: at, objective: "O1", id: "compat-check", mark: "compat-mark",
                                                         model: "compat:model", verdict: "confirmed", reason: "recorded",
                                                         text: "compatibility corpus")
    Samagotchi::ObjectivesTrack::STORE.write(
      session_dir, now: at, id: "compat-track", model: "compat:model", seen: "compat-seen", left_out: 0,
                   readings: { "O1" => { "reading" => "progress", "reason" => "compatibility corpus" } },
                   lines: { "O1" => "compat-line" }, mark: "compat-mark"
    )

    reminders = Samagotchi::ReminderStore.new
    reminders.register(name: "compatibility", description: "compatibility corpus", interval_minutes: 20)
    Samagotchi::ReminderCarry.write(session_dir, session_id: session_id, store: reminders, wall: at)
    reminders_path = File.join(session_dir, Samagotchi::ReminderCarry::FILE)
    normalize_json_store!(reminders_path) do |data|
      data["written_at"] = COMPAT_STAMP
      data["reminders"].each do |entry|
        entry["id"] = "compat-reminder"
        entry["next_fire_at"] = COMPAT_STAMP
      end
    end

    recap = Samagotchi::RecapStore.new(session_id_lookup: -> { session_id }, state_dir_lookup: -> { sessions_dir })
    recap.save(text: "The user was testing compatibility.", title: "Compatibility", created_at: COMPAT_STAMP)
    recap_path = File.join(session_dir, Samagotchi::RecapStore::FILE)

    Samagotchi::Session.reparent(session_id, to: "compat-parent", from: "compat-source", state_dir: sessions_dir)
    parent_path = File.join(session_dir, Samagotchi::Session::PARENT_FILE)
    normalize_json_store!(parent_path) { |data| data["at"] = COMPAT_STAMP }

    Samagotchi::Tools::DelegateCursors.update(session_id, "compat-child", state_dir: sessions_dir) do |cursor|
      cursor.with(reply_file: "output/compat-child.json", question_id: "compat-question")
    end
    delegates_path = File.join(session_dir, Samagotchi::Tools::DelegateCursors::FILE)

    tails = Samagotchi::ThinkingTails.new(session_dir: -> { session_dir }, clock: -> { at })
    [
      { type: :turn_started, turn_id: "compat-tail-turn" },
      { type: :generation_started, iteration: 1 },
      { type: :generation_chunk, iteration: 1, thinking: "compatibility thinking" },
      { type: :generation_completed, iteration: 1, finish_reason: "length" }
    ].each { |event| tails.call(event) }
    tails_path = File.join(session_dir, Samagotchi::ThinkingTails::FILE)

    [archive_path, pending_path, File.join(session_dir, Samagotchi::Objectives::CARDS_FILE),
     File.join(session_dir, Samagotchi::ObjectivesCheck::FILE), File.join(session_dir, Samagotchi::ObjectivesTrack::FILE),
     reminders_path, recap_path, parent_path, delegates_path, tails_path]
  end
  private_class_method :write_compat_session_stores!

  def normalize_json_store!(path)
    data = JSON.parse(File.read(path))
    yield data
    File.write(path, "#{JSON.pretty_generate(data)}\n")
  end
  private_class_method :normalize_json_store!

  # A session approval of a command and a rule's, in /compat-fixture, in
  # the versioned store Approvals#add writes.
  # @return [String] approvals.json
  def write_compat_approvals!(sessions_dir)
    store = Samagotchi::Guardrails::Approvals.new(dir: Samagotchi::Guardrails::Approvals.dir_for(sessions_dir))
    compat_approval_verdicts.each { |scope, verdict| store.add(verdict, scope) }
    data = JSON.parse(File.read(store.path))
    data.fetch(Samagotchi::Guardrails::Approvals::COLLECTION).each { |entry| entry["created_at"] = COMPAT_STAMP }
    File.write(store.path, "#{JSON.pretty_generate(data)}\n")
    FileUtils.rm_f(File.join(File.dirname(store.path), "approvals.lock"))
    store.path
  end
  private_class_method :write_compat_approvals!

  # The asks the corpus's approvals answer, by scope.
  # @return [Hash{String => Samagotchi::Guardrails::Verdict}]
  def compat_approval_verdicts
    context = Samagotchi::Guardrails::Context.new(cwd: "/compat-fixture", session_id: COMPAT_SESSION_ID)
    asks = { "session" => ["git push origin main", "git-push"], "rule" => ["rm -rf build", "rm-recursive"] }
    asks.transform_values do |command, rule|
      call = { name: "execute", content: command }
      verdict = Samagotchi::Guardrails::Verdict.new(call: call).ask!("compatibility corpus", rule: rule, source: "config")
      verdict.context = context
      verdict.targets = Samagotchi::Guardrails::Targets.for(call, context)
      verdict
    end
  end
  private_class_method :compat_approval_verdicts

  # A pair participant's grant bound to an identity (the store's
  # BOUND_VERSION) and its sidecar, both naming COMPAT_GRANT_ID, the store
  # keeping COMPAT_GRANT_TOKEN's digest.
  # @return [Array<String>] grants.json and participants.json
  def write_compat_grant!(sessions_dir, at)
    grants = Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: sessions_dir), clock: -> { at })
    grants.issue(session_id: COMPAT_SESSION_ID, name: "Compat", kind: "agent", ttl: Samagotchi::Grants::DEFAULT_TTL,
                 cap: 2.0, identity: "compat@example.com", mode: Samagotchi::Grants::PAIR_MODE,
                 on_write: Samagotchi::Participants.sidecar_writer(sessions_dir, [COMPAT_SESSION_ID]))
    store = JSON.parse(File.read(grants.path))
    store["grants"].each do |grant|
      grant["id"] = COMPAT_GRANT_ID
      grant["digest"] = Samagotchi::Grants.digest(COMPAT_GRANT_TOKEN)
    end
    File.write(grants.path, "#{JSON.pretty_generate(store)}\n")
    FileUtils.rm_f(File.join(File.dirname(grants.path), Samagotchi::Grants::LOCK))
    sidecar = File.join(Samagotchi::Session.session_dir(COMPAT_SESSION_ID, state_dir: sessions_dir),
                        Samagotchi::Participants::FILE)
    participants = JSON.parse(File.read(sidecar))
    participants["participants"].each { |entry| entry["id"] = COMPAT_GRANT_ID }
    File.write(sidecar, "#{JSON.pretty_generate(participants)}\n")
    [grants.path, sidecar]
  end
  private_class_method :write_compat_grant!

  # COMPAT_DRAWN_ID: a prompt, a read and its answer, and the line a Bridge's
  # TurnDrawings writes for that turn (the accumulator's fold of its events).
  # @return [String] the drawings file
  def write_compat_drawn_session!(sessions_dir, version, at)
    stamp = "2026-01-01T00:00:00.000Z"
    messages = [
      { role: "user", content: "compatibility corpus", turn_id: "compat-turn", at: stamp },
      { role: "model", content: "Reading.", tool_calls: [{ id: "c1", name: "read", arguments: '{"path":"README.md"}' }] },
      { role: "tool_response", content: "[read]\ncompat", tool_call_id: "c1", tool_ids: ["compat-t1"] },
      { role: "model", content: "It says compat." }
    ]
    Samagotchi::Session.new(id: COMPAT_DRAWN_ID, mode: "assist", model_name: "compat:model", working_directory: "/compat-fixture",
                            created_at: COMPAT_STAMP, updated_at: COMPAT_STAMP, messages: messages)
                       .save(state_dir: sessions_dir, now: at)
    session_path = Samagotchi::Session.session_file(COMPAT_DRAWN_ID, state_dir: sessions_dir)
    data = JSON.parse(File.read(session_path))
    data["written_by"] = version
    data["updated_at"] = COMPAT_STAMP
    File.write(session_path, "#{JSON.pretty_generate(data)}\n")
    session_dir = Samagotchi::Session.session_dir(COMPAT_DRAWN_ID, state_dir: sessions_dir)
    path = File.join(session_dir, Samagotchi::Bridge::TurnDrawings::FILE)
    drawings = Samagotchi::Bridge::TurnDrawings.new(path: path, messages: -> { messages })
    accumulator = Samagotchi::Bridge::TurnAccumulator.new(clock: -> { 0.0 }, on_turn_end: drawings.method(:append))
    activity = { tool: "read", status: "ok", params: 'path="README.md"', action: "reading file", title: "README.md" }
    [{ type: :turn_started, prompt: "compatibility corpus", turn_id: "compat-turn", at: stamp, origin: { client_id: "web:compat" } },
     { type: :generation_started, iteration: 1 }, { type: :generation_chunk, iteration: 1, text: "Reading.", thinking: "" },
     { type: :tool_call_started, iteration: 1, call_index: 1, tool: "read", params: 'path="README.md"', tool_id: "compat-t1",
       title: "README.md" },
     { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", tool_id: "compat-t1", output: "[read]\ncompat",
       output_truncated: false, duration_ms: 12, activity: activity },
     { type: :generation_started, iteration: 2 }, { type: :generation_chunk, iteration: 2, text: "It says compat.", thinking: "" },
     { type: :turn_completed, turn_id: "compat-turn", duration_ms: 40, kept_from: 0, kept_to: messages.size }]
      .each { |event| accumulator.call(event) }
    path
  end
  private_class_method :write_compat_drawn_session!

  def system_bundle_version(root)
    YAML.safe_load_file(File.join(root, SYSTEM_MANIFEST))["version"].to_s
  end

  # --- bundle manifests' sha256 lines -------------------------------------

  def bundle_dirs(root)
    Dir.glob(File.join(root, BUNDLES_DIR, "*", "manifest.yml")).map { |m| File.dirname(m) }.sort
  end

  # The manifest text with its sha256 lines recomputed, and the lines that
  # changed (MemoryBundle::Shas.refresh, which raises Shas::Error).
  def refresh_manifest(text, dir) = Samagotchi::MemoryBundle::Shas.refresh(dir, text)

  # Rewrites every bundle manifest whose sha lines are stale. Returns
  # {"bundle/manifest.yml" => changes}.
  def refresh_bundle_shas!(root)
    bundle_dirs(root).each_with_object({}) do |dir, out|
      manifest = File.join(dir, "manifest.yml")
      text, changes = refresh_manifest(File.read(manifest), dir)
      next if changes.empty?

      File.write(manifest, text)
      out["#{File.basename(dir)}/manifest.yml"] = changes
    end
  end

  def stale_shas(root)
    bundle_dirs(root).flat_map do |dir|
      Samagotchi::MemoryBundle::Shas.stale(dir).map do |stale|
        next "#{File.basename(dir)}: no sha256 line for #{stale.file} (add one, then rake bundles:sha)" if stale.old.nil?

        "#{File.basename(dir)}: stale sha256 for #{stale.file} (rake bundles:sha)"
      end
    end
  end

  # A shipped bundle's top-level *.md that its files: doesn't list: an
  # install takes only the listed ones (MemoryBundle::MemoryFiles), and a
  # listed file gets its sha line (rake bundles:sha).
  def unlisted_memories(root)
    bundle_dirs(root).flat_map do |dir|
      parsed = YAML.safe_load_file(File.join(dir, "manifest.yml")) || {}
      listed = parsed["files"].is_a?(Hash) ? parsed["files"].keys.map(&:to_s) : []
      (Dir.glob(File.join(dir, "*.md")).map { |f| File.basename(f) }.sort - listed).map do |file|
        "#{File.basename(dir)}: ships #{file}, which files: doesn't list (an install leaves it out; add it, then rake bundles:sha)"
      end
    end
  end

  # --- git --------------------------------------------------------------

  # The pathspecs of what a bundle ships: its folder without its spec/
  # (the bundle's own specs, never installed: a change there needs no
  # version bump).
  def shipped_paths(rel) = [rel, ":(exclude)#{rel}/spec"]

  def git(root, *)
    out, status = Open3.capture2e("git", "-C", root, *)
    [out, status.success?]
  end

  # The newest v* tag reachable from HEAD; a tag on HEAD itself only when
  # tracked files have changed since. In the release workflow HEAD is the
  # tag being released, with a clean tree: comparing a bundle with it would
  # find nothing changed, so the one before it counts. Before the tag is cut
  # (release:check) that is simply the newest tag; edits on top of a tagged
  # HEAD compare with that tag.
  def last_tag(root)
    _, clean = git(root, "diff", "--quiet", "HEAD")
    on_head = clean ? git(root, "tag", "--points-at", "HEAD", "--list", "v*").first : ""
    excludes = on_head.split.flat_map { |tag| ["--exclude", tag] }
    out, ok = git(root, "describe", "--tags", "--abbrev=0", "--match", "v*", *excludes, "HEAD")
    ok ? out.strip : nil
  end

  # A bundle whose directory differs from the tag (commits or uncommitted
  # edits to tracked files) must carry a higher version: only the system
  # bundle upgrades by itself; users upgrade the others with `chi bundle
  # upgrade`, which compares versions. A bundle new since the tag is fine.
  # +skip+: bundle names left out (CI mode leaves out the system bundle).
  def unbumped_bundles(root, tag, skip: [])
    bundle_dirs(root).filter_map do |dir|
      next if skip.include?(File.basename(dir))

      rel = dir.delete_prefix("#{File.expand_path(root)}/")
      _, same = git(root, "diff", "--quiet", tag, "--", *shipped_paths(rel))
      next if same

      old_text, existed = git(root, "show", "#{tag}:#{rel}/manifest.yml")
      next unless existed

      old = YAML.safe_load(old_text)["version"].to_s
      new = YAML.safe_load_file(File.join(dir, "manifest.yml"))["version"].to_s
      next if Gem::Version.new(new) > Gem::Version.new(old)

      "#{File.basename(dir)}: changed since #{tag} but still version #{new} (bump its manifest version)"
    end
  end

  # A bundle changed since the tag whose requires_chi the tagged chi already
  # meets: if the change uses anything new in chi, that chi would install it
  # and break (guardrails 0.2.0 and `models:` under 0.8.0). A warning only:
  # most bundle changes need nothing new (one that does is marked
  # requires_chi_next, and bundles_check drops its warning). A meta bundle (a profile, its
  # includes:) is left out: installing it checks each member's own
  # requires_chi (Profile.install_member), so its floor guards nothing
  # here (low_meta_floors keeps it at its members' highest).
  def stale_requires_chi(root, tag)
    tagged = Gem::Version.new(tag.delete_prefix("v"))
    bundle_dirs(root).filter_map do |dir|
      manifest = YAML.safe_load_file(File.join(dir, "manifest.yml"))
      next if manifest["includes"]

      requires = manifest["requires_chi"] or next
      next unless Gem::Requirement.new(*requires.to_s.split(",").map(&:strip)).satisfied_by?(tagged)

      _, same = git(root, "diff", "--quiet", tag, "--", *shipped_paths(dir.delete_prefix("#{File.expand_path(root)}/")))
      next if same

      "#{File.basename(dir)}: changed since #{tag} and requires_chi #{requires.to_s.inspect} admits that chi: " \
        "mark it requires_chi_next if the change uses anything newer"
    end
  end

  # A meta bundle (a profile, its includes:) whose requires_chi is below a
  # member's: [notes]. Nothing breaks (installing it checks each member's
  # own requires_chi, Profile.install_member), but the profile then claims
  # a chi its members don't run on. A note, not a failure: release:bump
  # raises such a profile with its members (raised_profile_floors), and
  # release:check, right after it, runs bundles:check in full.
  def low_meta_floors(root)
    low_profiles(root).map do |low|
      have = low.requires ? low.requires.to_s.inspect : "(none)"
      "#{low.name}: requires_chi #{have} is below member #{low.member}'s #{low.member_requires.inspect}: " \
        "raise it to \">= #{low.floor}\" (and bump #{low.name}'s version)"
    end
  end

  # A profile below its highest member: its manifest path, name and
  # requires_chi (nil for none), that member, its requires_chi and floor.
  LowProfile = Data.define(:path, :name, :requires, :member, :member_requires, :floor)

  # The profiles whose requires_chi is below a member's, as [LowProfile].
  # +texts+: {manifest path => text} read in place of the file (release:bump's
  # manifests before it writes them).
  def low_profiles(root, texts = {})
    read = ->(path) { YAML.safe_load(texts.fetch(path) { File.read(path) }) || {} }
    bundle_dirs(root).filter_map do |dir|
      path = File.join(dir, "manifest.yml")
      manifest = read.call(path)
      members = manifest["includes"] or next

      member, requires, floor = Array(members).filter_map do |name|
        member_path = File.join(root, BUNDLES_DIR, name.to_s, "manifest.yml")
        next unless File.file?(member_path)

        member_requires = read.call(member_path)["requires_chi"]
        member_floor = requires_floor(member_requires)
        [name.to_s, member_requires.to_s, member_floor] if member_floor
      end.max_by(&:last)
      own = requires_floor(manifest["requires_chi"])
      next unless floor && (own.nil? || own < floor)

      LowProfile.new(path: path, name: File.basename(dir), requires: manifest["requires_chi"],
                     member: member, member_requires: requires, floor: floor)
    end
  end

  # The lowest chi a requires_chi admits: its highest >=, >, ~> or = bound;
  # nil for none.
  def requires_floor(requires)
    return nil if requires.to_s.strip.empty?

    Gem::Requirement.new(*requires.to_s.split(",").map(&:strip)).requirements
                    .filter_map { |op, version| version if %w[>= > ~> =].include?(op) }.max
  end

  # --- requires_chi_next: a floor raised at release time -------------------

  # A bundle that needs something new in chi says so with
  # `requires_chi_next: true` (or a short reason) in its manifest instead of
  # raising requires_chi to a chi that isn't released yet (main would then
  # refuse its own bundle). `release:bump` turns the marker into
  # `requires_chi: ">= <released version>"`; `release:check` fails while one
  # is left. chi itself ignores the key.
  NEXT_KEY = "requires_chi_next"
  NEXT_LINE = /^#{NEXT_KEY}:[^\n]*\n?/
  REQUIRES_LINE = /^requires_chi:[^\n]*$/

  # {bundle dir => the marker's value} for every manifest that carries one.
  def requires_chi_next(root)
    bundle_dirs(root).each_with_object({}) do |dir, out|
      value = YAML.safe_load_file(File.join(dir, "manifest.yml"))&.fetch(NEXT_KEY, nil)
      out[dir] = value unless value.nil? || value == false
    end
  end

  # A marker that isn't `true` or a one-line reason, or that release:bump
  # couldn't rewrite (a multi-line value): [problems].
  def requires_chi_next_problems(root)
    requires_chi_next(root).filter_map do |dir, value|
      lines = File.read(File.join(dir, "manifest.yml")).scan(NEXT_LINE)
      shape_ok = value == true || (value.is_a?(String) && !value.strip.empty?)
      # One line that alone parses to the same value: not a block scalar
      # or a value continued on the next lines, which the rewrite would cut.
      next if shape_ok && lines.size == 1 && (YAML.safe_load(lines.first) || {})[NEXT_KEY] == value

      "#{File.basename(dir)}: #{NEXT_KEY}: must be `true` or a one-line reason, on its own top-level line"
    end
  end

  # The manifest text with requires_chi raised to ">= version" (replacing
  # the line, or added after `version:`) and the marker line dropped.
  def raise_requires_chi(text, version)
    line = %(requires_chi: ">= #{version}")
    text = text.sub(NEXT_LINE, "")
    return text.sub(REQUIRES_LINE, line) if text.match?(REQUIRES_LINE)

    text.sub(/^version:[^\n]*\n/) { |v| "#{v}#{line}\n" }
  end

  # The marked bundles' new manifest texts, {path => text}; raises (and so
  # changes nothing) on a marker it can't rewrite.
  def raised_requires_chi(root, version)
    problems = requires_chi_next_problems(root)
    raise Error, problems.join("; ") unless problems.empty?

    requires_chi_next(root).keys.to_h do |dir|
      path = File.join(dir, "manifest.yml")
      [path, raise_requires_chi(File.read(path), version)]
    end
  end

  # A profile raised with its members: its name, version before and after
  # (a patch bump) and its new requires_chi floor.
  RaisedProfile = Data.define(:name, :old_version, :version, :floor)

  # The profiles left below a member once +texts+ ({path => text}, the
  # members' raised manifests) are written: {path => text} with each one's
  # requires_chi raised to that member's floor and its version patch-bumped,
  # and the [RaisedProfile]s. A profile whose version already moved since
  # +tag+ (a member joined it this release), or that is new since it, keeps
  # its version: one release, one bump. Repeated until none is left below a
  # member, so a profile that is a member of another raises that one too
  # (floors only go up, so it ends).
  def raised_profile_floors(root, texts, tag: last_tag(root))
    original = ->(path) { texts.fetch(path) { File.read(path) } }
    current = texts.dup
    out = {}
    raised = {}
    until (lows = low_profiles(root, current)).empty?
      lows.each do |low|
        text = raise_requires_chi(current.fetch(low.path) { File.read(low.path) }, low.floor)
        text = patch_bump(text, low.name) unless out.key?(low.path) || bumped_since?(root, tag, low.path, text)
        current[low.path] = out[low.path] = text
        raised[low.path] = low
      end
    end
    profiles = raised.values.sort_by(&:name).map do |low|
      RaisedProfile.new(name: low.name, old_version: manifest_version(original.call(low.path)),
                        version: manifest_version(out[low.path]), floor: low.floor.to_s)
    end
    [out, profiles]
  end

  def manifest_version(text) = (YAML.safe_load(text) || {})["version"].to_s

  # Whether the manifest at +path+ (now +text+) is new since +tag+ or has a
  # higher version than at it; false without a tag.
  def bumped_since?(root, tag, path, text)
    return false unless tag

    rel = File.expand_path(path).delete_prefix("#{File.expand_path(root)}/")
    old_text, existed = git(root, "show", "#{tag}:#{rel}")
    return true unless existed

    Gem::Version.new(manifest_version(text)) > Gem::Version.new(manifest_version(old_text))
  end

  # The manifest text with its version's patch number raised (0.7.1 → 0.7.2).
  def patch_bump(text, name)
    old = manifest_version(text)
    raise Error, "#{name}: version #{old.inspect} isn't x.y.z" unless old.match?(/\A\d+\.\d+\.\d+\z/)

    major, minor, patch = old.split(".").map(&:to_i)
    text.sub(/^version:[^\n]*$/, "version: #{major}.#{minor}.#{patch + 1}")
  end

  # [problems, notes] for `rake bundles:check`. +ci+ (`rake
  # bundles:check[ci]`, the CI workflow): the changed-bundle version check
  # leaves out the system bundle, whose version moves only with VERSION at
  # `rake release:bump`, so it is changed and unbumped between releases.
  # The sha lines stay strict for every bundle.
  def bundles_check(root, ci: false)
    problems = stale_shas(root) + unlisted_memories(root) + requires_chi_next_problems(root)
    notes = low_meta_floors(root)
    marked = requires_chi_next(root).keys.map { |dir| File.basename(dir) }
    if (tag = last_tag(root))
      problems += unbumped_bundles(root, tag, skip: ci ? [SYSTEM_BUNDLE] : [])
      notes += stale_requires_chi(root, tag).reject { |n| marked.include?(n[/\A[^:]+/]) }
    else
      notes << "No v* tag yet: skipped the changed-bundle version check."
    end
    notes += marked.map { |name| "#{name}: #{NEXT_KEY} is set: rake release:bump raises its requires_chi" }
    [problems, notes]
  end

  # --- CHANGELOG ----------------------------------------------------------

  HEADING = /^## \[([^\]]+)\][^\n]*\n/
  LINK_REF = /^\[[^\]]+\]: \S+\s*$/

  # The body of `## [version]` (without its heading), stripped; nil when
  # there's no such section.
  def changelog_section(text, version)
    start = text.match(/^## \[#{Regexp.escape(version)}\][^\n]*\n/) or return nil
    rest = text[start.end(0)..]
    stop = [rest =~ /^## \[/, rest =~ LINK_REF, rest.length].compact.min
    rest[0...stop].strip
  end

  def released_versions(text)
    text.scan(HEADING).flatten - ["Unreleased"]
  end

  # `## [Unreleased]` becomes `## [version] - date` under a fresh empty
  # Unreleased; the compare links at the bottom follow.
  def release_changelog(text, version, date, repo: REPO_URL)
    raise Error, "CHANGELOG.md has no ## [Unreleased] section" unless text.match?(/^## \[Unreleased\]/)
    raise Error, "CHANGELOG.md already has a ## [#{version}] section" if released_versions(text).include?(version)
    raise Error, "## [Unreleased] is empty: write the notes first (rake release:draft_changelog)" if changelog_section(text, "Unreleased").to_s.empty?

    previous = released_versions(text).first
    body = text.sub(/^## \[Unreleased\][^\n]*\n/, "## [Unreleased]\n\n## [#{version}] - #{date}\n")
    body = body.lines.reject { |l| l.start_with?("[Unreleased]: ") }.join.rstrip
    links = ["[Unreleased]: #{repo}/compare/v#{version}...HEAD",
             "[#{version}]: #{previous ? "#{repo}/compare/v#{previous}...v#{version}" : "#{repo}/releases/tag/v#{version}"}"]
    first_link = body.lines.index { |l| l.match?(LINK_REF) }
    if first_link
      lines = body.lines
      (lines[0...first_link].join.rstrip + "\n\n" + links.join("\n") + "\n" + lines[first_link..].join).rstrip + "\n"
    else
      "#{body}\n\n#{links.join("\n")}\n"
    end
  end

  UPDATE_LINE = /Update\s+with\s+`chi update`(?: \(([^)]*)\))?/

  # The CHANGELOG with each raised profile (+profiles+, [RaisedProfile])
  # named in +version+'s "Update with `chi update`" line as "the NAME
  # profile X.Y.Z": added inside its parentheses (or a version it names
  # there replaced), parentheses added to a bare line, the line added at the
  # section's end when it has none. A line of its own wins over one inside a
  # bullet (the first such); either may wrap.
  def name_profiles_in_changelog(text, version, profiles)
    return text if profiles.empty?

    start = text.match(/^## \[#{Regexp.escape(version)}\][^\n]*\n/) or return text
    rest = text[start.end(0)..]
    stop = [rest =~ /^## \[/, rest =~ LINK_REF, rest.length].compact.min
    section = rest[0...stop]
    named = lambda do |items|
      profiles.reduce(items) do |list, p|
        item = "the #{p.name} profile #{p.version}"
        pattern = /the #{Regexp.escape(p.name)} profile [\d.]+/
        list.match?(pattern) ? list.sub(pattern, item) : [list, item].reject(&:empty?).join(", ")
      end
    end
    # The section's own line (at a line's start) first, else the first one
    # inside a bullet.
    found = section.match(/^#{UPDATE_LINE}/) || section.match(UPDATE_LINE)
    section = if found
                "#{found.pre_match}Update with `chi update` (#{named.call(found[1].to_s)})#{found.post_match}"
              else
                "#{section.rstrip}\n\nUpdate with `chi update` (#{named.call("")}).\n\n"
              end
    text[0...start.end(0)] + section + rest[stop..]
  end

  # --- bump ---------------------------------------------------------------

  COMPAT_WIRE_FIXTURE_REFRESH_COMMAND =
    "UPDATE_COMPAT_WIRE=1 bundle exec rspec spec/compat/wire_readers_spec.rb"

  # Refresh the shared wire fixtures in a fresh process so it loads the
  # version and compatibility corpus just written by the bump.
  def refresh_compat_wire_fixtures!(root, runner: ->(command, chdir:) { Open3.capture2e("sh", "-c", command, chdir: chdir) })
    output, status = runner.call(COMPAT_WIRE_FIXTURE_REFRESH_COMMAND, chdir: root)
    return if status.success?

    detail = output.to_s.strip
    raise Error, "compat wire fixture refresh failed; rerun from #{root}: " \
                 "`#{COMPAT_WIRE_FIXTURE_REFRESH_COMMAND}`#{"\n#{detail}" unless detail.empty?}"
  end

  # What bump! changed: the version before, the bundles whose
  # requires_chi_next it turned into requires_chi, and the [RaisedProfile]s.
  # +since+: the entries moved out of an Unreleased SINCE comment,
  # {rel_path => [names]} (release_since).
  Bumped = Data.define(:old, :raised, :profiles, :since)

  # VERSION, the system manifest's version, Gemfile.lock's samagotchi lines,
  # the CHANGELOG, the requires_chi of every bundle marked requires_chi_next
  # (raised to ">= version", the marker dropped), and then every profile
  # below a member's requires_chi (raised to it, with a patch bump of the
  # profile's version unless it moved since the last tag; named in the
  # CHANGELOG's "Update with `chi update`" line). No other requires_chi is
  # touched. The Unreleased comments in Plugin::Api::SINCE and
  # Manifest::SINCE become entries at +version+ (release_since). No commit;
  # a Bumped.
  def bump!(root, version, date: Time.now.strftime("%Y-%m-%d"))
    raise Error, "#{version.inspect} isn't a version (x.y.z)" unless version.match?(VERSION_PATTERN)

    current = gem_version(root)
    raise Error, "#{version} isn't above the current #{current}" unless Gem::Version.new(version) > Gem::Version.new(current)

    changelog = File.join(root, CHANGELOG)
    new_changelog = release_changelog(File.read(changelog), version, date)
    raised = raised_requires_chi(root, version)
    profile_texts, profiles = raised_profile_floors(root, raised)
    new_changelog = name_profiles_in_changelog(new_changelog, version, profiles)
    since_texts, since = released_since(root, version)

    edit(root, VERSION_FILE) { |t| t.sub(/VERSION = "[^"]+"/, %(VERSION = "#{version}")) }
    edit(root, SYSTEM_MANIFEST) { |t| t.sub(/^version: .*$/, "version: #{version}") }
    edit(root, "Gemfile.lock") { |t| t.gsub(/^(\s+)samagotchi \(#{Regexp.escape(current)}\)$/, "\\1samagotchi (#{version})") }
    File.write(changelog, new_changelog)
    raised.merge(profile_texts).merge(since_texts).each { |path, text| File.write(path, text) }
    write_compat_corpus!(root, version)
    Bumped.new(old: current, raised: raised.keys.map { |path| File.basename(File.dirname(path)) }, profiles: profiles,
               since: since)
  end

  # The SINCE tables' new texts, {path => text}, and the names each moved,
  # {rel => [names]}, for the tables that hold an Unreleased comment; raises
  # (so bump! writes nothing) on a comment that names no entry.
  def released_since(root, version)
    [PLUGIN_API, MANIFEST_KEYS].each_with_object([{}, {}]) do |rel, (texts, since)|
      path = File.join(root, rel)
      next unless File.exist?(path)

      text = File.read(path)
      new_text, names = begin
        release_since(text, version)
      rescue Error => e
        raise Error, "#{rel}: #{e.message}"
      end
      next if names.empty?

      texts[path] = new_text
      since[rel] = names
    end
  end

  SINCE_OPEN = /\A\s*SINCE = \{\s*\z/
  SINCE_CLOSE = /\A\s*\}\.freeze\s*\z/
  COMMENT_LINE = /\A\s*#/
  # The comment's one shape, its wrapped lines joined: `Unreleased`, any
  # words without a quote up to a colon, then the quoted names.
  UNRELEASED_SHAPE = /\AUnreleased\b[^"]*?:\s*((?:"[^"]+"\s*,\s*)*"[^"]+")\s*\.?\z/

  # The text with the SINCE table's Unreleased comment (UNRELEASED_API,
  # with the lines it wraps onto) turned into one `"name" => "version"`
  # line per quoted name, at the comment's indent, and a comma given to the
  # entry before it; [new text, names]. Only inside `SINCE = {` ...
  # `}.freeze`, and only a comment right before the closing `}`. A text
  # with no comment there comes back as it is, with no names. Raises Error
  # (bump! then writes nothing) for a comment elsewhere in the table, one
  # not of its shape, a name the table has already, or a result that
  # doesn't parse.
  def release_since(text, version)
    lines = text.lines
    open = lines.index { |l| l.match?(SINCE_OPEN) } or return [text, []]
    close = ((open + 1)...lines.size).find { |i| lines[i].match?(SINCE_CLOSE) } or return [text, []]
    at = ((open + 1)...close).find { |i| lines[i].match?(UNRELEASED_API) } or return [text, []]
    unless (at...close).all? { |i| lines[i].match?(COMMENT_LINE) }
      raise Error, "the Unreleased SINCE comment must be the table's last lines, right before its closing }: #{lines[at].strip}"
    end

    comment = lines[at...close].map { |l| l.strip.sub(/\A#\s*/, "") }.join(" ")
    quoted = comment.match(UNRELEASED_SHAPE) or
      raise Error, "the Unreleased SINCE comment names no entry (# Unreleased (...): \"name\", \"name\".): #{comment}"
    names = quoted[1].scan(/"([^"]+)"/).flatten
    entries = lines[(open + 1)...at].grep_v(COMMENT_LINE).join.scan(/"([^"]+)"\s*=>/).flatten
    taken = names & entries
    raise Error, "the Unreleased SINCE comment names #{taken.join(", ")}, which SINCE has already" unless taken.empty?

    before = (at - 1).downto(open + 1).find { |i| !lines[i].strip.empty? && !lines[i].match?(COMMENT_LINE) }
    if before
      code, note = lines[before].chomp.match(/\A(.*?)(\s+#[^"]*)?\z/).captures
      lines[before] = "#{code.rstrip.end_with?(",") ? code.rstrip : "#{code.rstrip},"}#{note}\n"
    end
    indent = lines[at][/\A\s*/]
    lines[at...close] = ["#{names.map { |name| %(#{indent}"#{name}" => "#{version}") }.join(",\n")}\n"]
    out = lines.join
    raise Error, "moving #{names.join(", ")} into SINCE would leave a file that doesn't parse" unless Prism.parse(out).success?

    [out, names]
  end

  def edit(root, rel)
    path = File.join(root, rel)
    text = File.read(path)
    new = yield text
    raise Error, "#{rel}: nothing to change" if new == text

    File.write(path, new)
  end

  # --- draft changelog ----------------------------------------------------

  SKIP = /\A(Merge |fixup! |squash! |amend! |Revert "|WIP\b)|\A(System bundle and gem|Bump|Version) [\d.]+\z/i
  FIXED = /\b(fix(es|ed)?|bug|crash(es|ed)?|regression|broken|no longer|instead of|wrong|(it|they) (said|was|were|showed))\b|n't\b.*\(|\bstale\b/i
  ADDED = /\A(add(s|ed)?|new|introduce|support)\b|\bnew (command|flag|setting|tool|bundle|option)\b/i

  def classify(subject)
    return nil if subject.match?(SKIP)
    return "Fixed" if subject.match?(FIXED)
    return "Added" if subject.match?(ADDED)

    "Changed"
  end

  # A draft `## [Unreleased]` from commit subjects, grouped; the agent edits
  # it into user-facing lines before the user approves it.
  def draft_changelog(subjects)
    groups = { "Added" => [], "Changed" => [], "Fixed" => [] }
    subjects.each { |s| (g = classify(s.strip)) and groups[g] << s.strip }
    out = +"## [Unreleased]\n"
    groups.each do |name, items|
      next if items.empty?

      out << "\n### #{name}\n\n" << items.map { |s| "- #{s}\n" }.join
    end
    out
  end

  def subjects_since(root, tag)
    range = tag ? "#{tag}..HEAD" : "HEAD"
    out, ok = git(root, "log", "--no-merges", "--reverse", "--format=%s", range)
    raise Error, "git log failed: #{out}" unless ok

    out.lines.map(&:chomp).reject(&:empty?)
  end

  # --- release:check pieces ---------------------------------------------

  def dirty_tracked_files(root)
    out, ok = git(root, "status", "--porcelain", "--untracked-files=no")
    raise Error, "git status failed: #{out}" unless ok

    out.lines.map(&:chomp)
  end

  def compatibility_corpus_problem(root, version)
    relative = "spec/compat/#{version}"
    directory = File.join(root, relative)
    return "#{relative} is missing" unless Dir.exist?(directory)

    files = Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).select { |path| File.file?(path) }
    return "#{relative} is empty" if files.empty?

    tracked, ok = git(root, "ls-files", "-z", "--", relative)
    raise Error, "git ls-files failed: #{tracked}" unless ok

    tracked = tracked.split("\0")
    untracked = files.map { |path| path.delete_prefix("#{File.expand_path(root)}/") } - tracked
    return "#{relative} has untracked files: #{untracked.join(", ")}" unless untracked.empty?
    return "#{relative} has no tracked files" if tracked.empty?

    nil
  end

  # The checks that need no build: [problems].
  def consistency_problems(root)
    version = gem_version(root)
    problems = []
    dirty = dirty_tracked_files(root)
    problems << "uncommitted changes to tracked files:\n  #{dirty.join("\n  ")}" unless dirty.empty?
    corpus = compatibility_corpus_problem(root, version)
    problems << corpus if corpus
    system = system_bundle_version(root)
    problems << "VERSION #{version} != system bundle #{system}" unless system == version
    changelog = File.join(root, CHANGELOG)
    section = File.exist?(changelog) ? changelog_section(File.read(changelog), version) : nil
    problems << "CHANGELOG.md has no (or an empty) ## [#{version}] section" if section.to_s.empty?
    requires_chi_next(root).each_key do |dir|
      problems << "#{File.basename(dir)}: #{NEXT_KEY} is still set: raise its requires_chi to \">= #{version}\" " \
                  "and drop the marker (rake release:bump does both)"
    end
    problems << remote_not_yet_problem if remote_not_yet?(root)
    problems.concat(unreleased_api_problems(root, version))
    problems
  end

  # A new plugin API call waits in a comment in Plugin::Api::SINCE until it
  # is released (docs/releasing.md); a release that left it there ships it
  # with no floor for `chi bundle check`'s requires-chi-floor. A new manifest
  # key waits the same way in Manifest::SINCE.
  PLUGIN_API = "lib/samagotchi/plugin/api.rb"
  MANIFEST_KEYS = "lib/samagotchi/memory_bundle/manifest.rb"
  UNRELEASED_API = /^\s*#\s*Unreleased\b.*$/

  def unreleased_api_problems(root, version)
    [[PLUGIN_API, "Plugin::Api::SINCE"], [MANIFEST_KEYS, "Manifest::SINCE"]].filter_map do |rel, table|
      path = File.join(root, rel)
      comment = File.exist?(path) ? File.read(path)[UNRELEASED_API] : nil
      next unless comment

      "#{rel}: #{table}'s Unreleased comment still names #{comment.scan(/"([^"]+)"/).flatten.join(", ")}: " \
        "give each \"#{version}\" in SINCE and drop the comment"
    end
  end

  # The remote attach's temporary refusals (TerminalUI::RemoteLink::NOT_YET:
  # /exit, /archive, /stats, /recap through a remote) ship only with their
  # routes (remote-sessions P4-D8: P4a and P4b in one release).
  REMOTE_LINK = "lib/samagotchi/terminal_ui/remote_link.rb"

  def remote_not_yet?(root)
    path = File.join(root, REMOTE_LINK)
    File.exist?(path) && File.read(path).match?(/^\s*NOT_YET\s*=/)
  end

  def remote_not_yet_problem
    "#{REMOTE_LINK}: RemoteLink::NOT_YET is still defined: the remote attach's /exit, /archive, /stats and " \
      "/recap need their chi web routes (P4b) before a release"
  end
end
