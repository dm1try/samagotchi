# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_row"

RSpec.describe Samagotchi::SessionRow do
  let(:state_dir) { Dir.mktmpdir("session-row") }

  after { FileUtils.rm_rf(state_dir) }

  def make(prompt: "hello", status: nil, parent_id: nil, continues: nil, title: nil, pending: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
      s.last_prompt = prompt
      s.status = status if status
      s.parent_id = parent_id
      s.continues = continues
      s.title = title
      s.pending_question = pending if pending
      s.save(state_dir: state_dir)
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir).tap { |d| FileUtils.mkdir_p(d) }

  def owner(kind) = Samagotchi::OwnerLock::Owner.new(pid: Process.pid, kind: kind, started_at: Time.now.iso8601)

  def row(session, owner: nil, **opts) = described_class.build(session, session_dir: dir_of(session), owner: owner, **opts)

  def question(kind: "question")
    { "id" => "q1", "kind" => kind, "question" => "which?", "created_at" => Time.now.iso8601 }
  end

  describe ".build" do
    it "reads a dead worker's saved running as idle, not live, not busy; saved_status keeps the file's" do
      expect(row(make(status: Samagotchi::Session::STATUS_RUNNING)))
        .to have_attributes(status: "idle", saved_status: "running", live: false, busy: false, owner: nil)
    end

    it "is live, busy and waiting only with a worker" do
      session = make(status: Samagotchi::Session::STATUS_RUNNING, pending: question)

      expect(row(session, owner: owner("worker"))).to have_attributes(status: "running", live: true, busy: true,
                                                                      owner: "worker", waiting: "question",
                                                                      waiting_id: "q1")
      expect(row(session)).to have_attributes(live: false, busy: false, waiting: nil, waiting_id: nil)
    end

    it "counts a kind-less Starting owner live (WorkerLink's worker_owned?)" do
      expect(row(make, owner: owner(nil))).to have_attributes(live: true, owner: nil)
    end

    it "reads a one-shot's turn as owned and running, not live" do
      session = make(status: Samagotchi::Session::STATUS_RUNNING, pending: question)

      expect(row(session, owner: owner("tui"))).to have_attributes(status: "running", live: false, busy: false,
                                                                   owner: "tui", waiting: nil)
    end

    it "takes recap and auto_title from one recap read" do
      session = make
      File.write(File.join(dir_of(session), "recap.json"),
                 JSON.generate(text: "Fixed the login. Then more.", title: "Login fix", covered: 2))

      expect(row(session)).to have_attributes(recap: "Fixed the login.", auto_title: "Login fix")
    end

    it "counts ctx_pct against the session's budget" do
      session = make
      File.write(File.join(dir_of(session), "analytics.json"),
                 JSON.generate("context" => { "used_tokens" => 12_340, "window_tokens" => 100_000 }))

      expect(row(session).ctx_pct).to eq(12.3)
      expect(row(session, budgets: ->(_) { 20_000 }).ctx_pct).to eq(61.7)
    end

    it "derives the short ids" do
      session = make(parent_id: "p" * 36, continues: "c" * 36)

      expect(row(session)).to have_attributes(short_id: session.id[0, 8], parent_short_id: "pppppppp",
                                              continues_short_id: "cccccccc")
    end
  end

  describe ".running_or_starting?" do
    def ask(**facts) = described_class.running_or_starting?(saved_status: "running", live: false, busy: false, **facts)

    it "is busy, or saved running with no worker for less than 15 s" do
      expect(ask(busy: true, live: true, updated_at: nil)).to be(true)
      expect(ask(updated_at: (Time.now - 5).iso8601)).to be(true)
      expect(ask(updated_at: (Time.now - 20).iso8601)).to be(false)
      expect(ask(live: true, updated_at: Time.now.iso8601)).to be(false)
      expect(ask(saved_status: "idle", updated_at: Time.now.iso8601)).to be(false)
      expect(ask(updated_at: "not a time")).to be(false)
    end
  end

  describe ".summary_text" do
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w") }

    it "is the title when set, else the last prompt, else the first message" do
      session.first_preview = "hey chi"
      expect(described_class.summary_text(session)).to eq("hey chi")
      session.last_prompt = "> quoted\n\nfix   it"
      expect(described_class.summary_text(session)).to eq("quoted fix it")
      session.title = "  Coordinator \n of the day "
      expect(described_class.summary_text(session)).to eq("Coordinator of the day")
      session.title = " "
      expect(described_class.summary_text(session)).to eq("quoted fix it")
    end
  end

  describe "#cli_line" do
    def line(**fields)
      described_class.from_summary_h({ id: "i" * 36, status: "idle", updated_at: "2026-11-08T10:00:00Z",
                                       preview: "the prompt" }.merge(fields)).cli_line
    end

    it "prints the state, the context's fill, updated_at and the text" do
      expect(line).to eq("#{"i" * 36}  idle      #{" " * 8}  2026-11-08T10:00:00Z  the prompt")
      expect(line(status: "running", ctx_pct: 12.3)).to start_with("#{"i" * 36}  running   ctx 12%   ")
    end

    it "says waiting for a question, and in which parent's card a relayed one waits" do
      expect(line(waiting: "question")).to include("  waiting   ")
      expect(line(waiting: "approval", relayed_to: "pppppppp")).to include("  waiting (in parent pppppppp)  ")
    end

    it "takes a title, else the recap's auto title, else its first sentence, else the prompt; 60 characters" do
      expect(line(title: "Named", preview: "Named", auto_title: "Auto")).to end_with("  Named")
      expect(line(auto_title: "Auto", recap: "Recap.")).to end_with("  Auto")
      expect(line(recap: "Recap.")).to end_with("  Recap.")
      expect(line(recap: "r" * 100)).to end_with("  #{"r" * 60}")
    end

    it "adds the flags and the links" do
      expect(line(test_run: true, archived: true, stopped_by: "loop-guard", parent_id: "p" * 36, continues: "c" * 36))
        .to end_with("the prompt [test] [archived] [looped]  ↳ pppppppp  ↪ cccccccc")
      expect(line(scratch: true, test_run: true, stopped_by: "check-in")).to end_with(" [scratch] [stopped by check-in]")
    end
  end

  describe "#to_summary_h" do
    it "has the summaries route's 28 keys, in order" do
      expect(row(make).to_summary_h.keys).to eq(
        %i[id short_id desc preview title cwd project updated_at status saved_status live busy owner recap auto_title
           ctx_pct parent_id parent_short_id continues continues_short_id delegate archived scratch test_run stopped_by
           waiting waiting_id relayed_to]
      )
    end

    it "reads back through JSON as the same row (.from_summary_h)" do
      session = make(status: Samagotchi::Session::STATUS_RUNNING, parent_id: "p" * 36, title: "Named",
                     pending: question(kind: "approval"))
      File.write(File.join(dir_of(session), "analytics.json"),
                 JSON.generate("context" => { "used_tokens" => 1, "window_tokens" => 3 }))
      original = row(session, owner: owner("worker"))
      wire = JSON.parse(JSON.generate(original.to_summary_h)).to_h { |key, value| [key.to_sym, value] }

      expect(described_class.from_summary_h(wire)).to eq(original)
    end

    it "keeps the web summary's 38 keys in their order (Web::SessionSummary::WEB_KEYS)" do
      require "samagotchi/web/session_summary"
      expect(Samagotchi::Web::SessionSummary::WEB_KEYS).to eq(
        %i[id status mode model_name working_directory created_at updated_at last_prompt short_id test_run
           used_memory_names preloaded_memory_names muted_memory_names prompt_notes parent_id delegate continues review
           first_preview title owner recap auto_title ctx_pct tokens memory_index side archived project_root bridge_up
           worker_version worker_features pending_question pending_card last_turn verdicts verify_fresh last_verdict]
      )
    end

    it "gives chi sessions list --format json 22 of them, no status (JSON_KEYS)" do
      expect(described_class::JSON_KEYS).to eq(
        %i[id short_id desc title auto_title cwd project updated_at live busy owner recap parent_id continues delegate
           archived scratch ctx_pct waiting waiting_id relayed_to stopped_by]
      )
      expect(described_class::JSON_KEYS - described_class::SUMMARY_KEYS).to be_empty
    end

    it "reads a missing key as nil" do
      expect(described_class.from_summary_h({ id: "x" })).to have_attributes(id: "x", live: nil, status: nil)
    end
  end
end
