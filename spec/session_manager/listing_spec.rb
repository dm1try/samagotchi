# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".list_sessions" do
    it "returns all sessions" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      sessions = described_class.list_sessions(state_dir: tmpdir)
      expect(sessions.length).to eq(1)
      expect(sessions.first.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end
  end

  describe ".read_responses" do
    it "only returns outputs strictly newer than since_time" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      output_dir = File.join(session_dir, Samagotchi::SessionInbox::OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)

      old_file = File.join(output_dir, "old.txt")
      new_file = File.join(output_dir, "new.txt")
      File.write(old_file, "old")
      boundary = Time.now
      File.write(new_file, "new")
      distinct_mtime(new_file)

      responses = described_class.read_responses(session.id, since_time: boundary, state_dir: tmpdir)
      expect(responses).to eq(["new"])
    end
  end

  describe ".session_summaries" do
    let(:locks) { [] }

    after { locks.each(&:release) }

    def make(cwd: "/work/app", prompt: "hello", updated: "2026-09-24T10:00:00Z", status: nil, test_run: false, preview: "",
             parent_id: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
        s.last_prompt = prompt
        s.parent_id = parent_id
        s.first_preview = preview
        s.status = status if status
        s.test_run = test_run
        s.save(state_dir: tmpdir)
        # save stamps updated_at; set it after for a fixed order
        data = JSON.parse(File.read(File.join(tmpdir, "#{s.id}.json")))
        File.write(File.join(tmpdir, "#{s.id}.json"), JSON.generate(data.merge("updated_at" => updated)))
      end
    end

    def own(session, kind: "worker")
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: kind)
    end

    def ids(**opts) = described_class.session_summaries(state_dir: tmpdir, **opts).map { |s| s[:id] }

    it "sums a session up: short id, a one-line description, cwd, liveness and whether a turn runs" do
      session = make(cwd: "/work/app", prompt: "fix   the\nlogin page", status: Samagotchi::Session::STATUS_RUNNING)
      own(session)

      summary = described_class.session_summaries(state_dir: tmpdir).first

      expect(summary).to include(id: session.id, short_id: session.id[0, 8], desc: "app · fix the login page",
                                 cwd: "/work/app", updated_at: "2026-09-24T10:00:00Z", live: true, busy: true)
    end

    it "tells a delegate child from a fork: both carry the parent, only one is a delegate" do
      parent = make(prompt: "plan")
      fork = make(parent_id: parent.id)
      delegate = make(parent_id: parent.id).tap do |s|
        s.delegate = true
        s.save(state_dir: tmpdir)
      end

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s[:delegate]] }
      expect(rows.values_at(parent.id, fork.id, delegate.id)).to eq([false, false, true])
    end

    it "carries the parent link, and .children_of lists a parent's children newest first" do
      parent = make(prompt: "plan", updated: "2026-09-24T09:00:00Z")
      older = make(prompt: "first task", updated: "2026-09-24T10:00:00Z", parent_id: parent.id)
      newer = make(prompt: "second task", updated: "2026-09-24T11:00:00Z", parent_id: parent.id,
                   status: Samagotchi::Session::STATUS_RUNNING)
      own(newer)

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s] }
      expect(rows[parent.id]).to include(parent_id: nil, parent_short_id: nil)
      expect(rows[older.id]).to include(parent_id: parent.id, parent_short_id: parent.id[0, 8])

      children = described_class.children_of(parent.id, state_dir: tmpdir)
      expect(children.map { |s| s[:id] }).to eq([newer.id, older.id])
      expect(children.count { |s| s[:busy] }).to eq(1)
      expect(described_class.children_of(nil, state_dir: tmpdir)).to eq([])
      expect(described_class.children_of(older.id, state_dir: tmpdir)).to eq([])
    end

    it "carries the link to the session it continues" do
      previous = make(prompt: "monday")
      today = make(prompt: "tuesday").tap do |s|
        s.continues = previous.id
        s.save(state_dir: tmpdir)
      end

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s] }
      expect(rows[previous.id]).to include(continues: nil, continues_short_id: nil)
      expect(rows[today.id]).to include(continues: previous.id, continues_short_id: previous.id[0, 8])
    end

    it "cuts a long description to 60 characters and falls back to the first preview" do
      long = make(prompt: "x" * 100)
      preview = make(prompt: "", preview: "from the preview", updated: "2026-09-23T10:00:00Z")

      by_id = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s[:desc]] }

      expect(by_id[long.id].length).to eq(60)
      expect(by_id[long.id]).to end_with("…")
      expect(by_id[preview.id]).to eq("app · from the preview")
    end

    it "drops the quote markers of a quoted or annotated message from the description" do
      quoted = make(prompt: "> answer:\n> the build failed\n>\n> > nested\n\nsame bug?")

      summary = described_class.session_summaries(state_dir: tmpdir).find { |s| s[:id] == quoted.id }

      expect(summary[:desc]).to eq("app · answer: the build failed nested same bug?")
      expect(summary[:preview]).to eq("answer: the build failed nested same bug?")
    end

    it "WorkerLink reads a session worker-owned only while a worker holds it, not a one-shot" do
      worker = make
      repl = make
      none = make
      own(worker)
      own(repl, kind: "tui")

      owned = ->(session) { Samagotchi::WorkerLink.resolve(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), unlink: false).worker_owned? }
      expect(owned.call(worker)).to be(true)
      expect(owned.call(repl)).to be(false)
      expect(owned.call(none)).to be(false)
    end

    it "live: only sessions a worker owns now, not a one-shot's and not a stale running status" do
      worker = make(updated: "2026-09-24T10:00:00Z")
      repl = make(updated: "2026-09-24T11:00:00Z")
      stale = make(updated: "2026-09-24T12:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      own(worker)
      own(repl, kind: "tui")

      expect(ids(live: true)).to eq([worker.id])
      expect(ids).to eq([stale.id, repl.id, worker.id])
      expect(described_class.session_summaries(state_dir: tmpdir).find { |s| s[:id] == stale.id })
        .to include(live: false, busy: false)
    end

    it "shows a crashed worker's 'running' as idle, as chi web does (Session#displayed_status); saved_status keeps the file's" do
      crashed = make(updated: "2026-09-24T10:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      worker = make(updated: "2026-09-24T11:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      repl = make(updated: "2026-09-24T12:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      own(worker)
      own(repl, kind: "tui")

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s] }
      expect(rows[crashed.id]).to include(status: "idle", saved_status: "running", live: false, busy: false)
      expect(rows[worker.id]).to include(status: "running", saved_status: "running", busy: true)
      expect(rows[repl.id]).to include(status: "running", live: false)
    end

    it "filters before it takes the limit" do
      live_one = make(updated: "2026-09-24T09:00:00Z")
      make(updated: "2026-09-24T10:00:00Z")
      make(updated: "2026-09-24T11:00:00Z")
      own(live_one)

      expect(ids(live: true, limit: 1)).to eq([live_one.id])
      expect(ids(limit: 2).size).to eq(2)
    end

    it "cwd: the folder or below it, not a sibling that shares its prefix" do
      top = make(cwd: "/work/app", updated: "2026-09-24T12:00:00Z")
      below = make(cwd: "/work/app/web", updated: "2026-09-24T11:00:00Z")
      make(cwd: "/work/apple", updated: "2026-09-24T10:00:00Z")

      expect(ids(cwd: "/work/app")).to eq([top.id, below.id])
      expect(ids(cwd: "/work/app/")).to eq([top.id, below.id])
    end

    it "leaves out test runs on request, and a given session (the asking one)" do
      mine = make(updated: "2026-09-24T12:00:00Z")
      test = make(test_run: true, updated: "2026-09-24T11:00:00Z")
      other = make(updated: "2026-09-24T10:00:00Z")

      expect(ids).to include(test.id)
      expect(ids(include_tests: false, exclude: mine.id)).to eq([other.id])
    end

    it "counts a row's ctx_pct against the session's llm_context budget when it is smaller than the window" do
      plain = make(updated: "2026-09-24T11:00:00Z")
      budgeted = make(updated: "2026-09-24T10:00:00Z")
      budgeted.model_name = "box:gemma-small"
      budgeted.llm_context = Samagotchi::LLMContextOverride.new(budget_tokens: 20_000)
      budgeted.save(state_dir: tmpdir)
      [plain, budgeted].each do |s|
        dir = Samagotchi::Session.session_dir(s.id, state_dir: tmpdir)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "analytics.json"),
                   JSON.generate("context" => { "used_tokens" => 12_340, "window_tokens" => 100_000 }))
      end

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s[:ctx_pct]] }
      expect(rows[budgeted.id]).to eq(61.7)
      expect(rows[plain.id]).to eq(12.3)
    end
  end
end
