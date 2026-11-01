# frozen_string_literal: true

require "samagotchi/system_one"
require "samagotchi/session_manager"
require "samagotchi/session_retention"
require "samagotchi/guardrails/chi_dirs"

RSpec.describe Samagotchi::SystemOne::RunsStore do
  let(:root) { Dir.mktmpdir("runs-store") }
  let(:store) { described_class.new(root) }
  let(:runs) { Samagotchi::SystemOne::Runs.new(store: store) }
  let(:question) { Samagotchi::SystemOne::Question.new(id: "allow", type: :noul, instructions: "Allow?") }

  after { FileUtils.rm_rf(root) }

  def run(id: "approvals.allow/1", session: "s1", state: "git push", at: nil)
    allow(Time).to receive(:now).and_return(at) if at
    runs.record(id: id, judgment: "approvals.allow", questions: [question], state: state, session_id: session)
    allow(Time).to receive(:now).and_call_original if at
  end

  def day_path(day, judgment: "approvals.allow") = File.join(root, "system_one", "runs", judgment, "#{day}.jsonl")
  def today = Time.now.utc.strftime("%F")

  it "writes one line a run to the judgment's day file, 0600, in a 0700 folder" do
    run
    expect(File.stat(day_path(today)).mode & 0o777).to eq(0o600)
    expect(File.stat(File.dirname(day_path(today))).mode & 0o777).to eq(0o700)
    expect(store.lines("approvals.allow").map { |line| line["id"] }).to eq(["approvals.allow/1"])
  end

  it "stores the questions once per digest pair" do
    2.times { |index| run(id: "approvals.allow/#{index}") }
    runs.record(id: "approvals.allow/2", judgment: "approvals.allow", questions: [question.with(instructions: "Allow this?")])
    versions = store.versions("approvals.allow")
    expect(versions.size).to eq(2)
    expect(versions.first["questions"]["allow"]).to eq("type" => "noul", "instructions" => "Allow?")
    expect(File.stat(File.join(File.dirname(day_path(today)), "versions.jsonl")).mode & 0o777).to eq(0o600)
  end

  it "cuts a state past the line cap, whatever its shape, and marks it" do
    [+"x" * 40_000, { "diff" => "\"quoted\"\n" * 8000 }, +"é" * 20_000].each_with_index do |state, index|
      run(id: "approvals.allow/#{index}", state: state)
    end
    lines = File.readlines(day_path(today))
    expect(lines.map(&:bytesize)).to all(be <= described_class::MAX_LINE_BYTES + 1)
    parsed = store.lines("approvals.allow")
    expect(parsed.size).to eq(3)
    expect(parsed.map { |line| line["truncated"] }).to all(be(true))
    expect(parsed).to all(include("state" => a_kind_of(String)))
    # As little as fits: escaping costs line bytes, it doesn't cost the state.
    expect(lines.map(&:bytesize)).to all(be > described_class::MAX_LINE_BYTES - 64)
    expect(parsed[0]["state"].bytesize).to be > 15_000
    expect(parsed[1]["state"].bytesize).to be > 4_000
    expect(parsed[2]["state"]).to be_valid_encoding
    expect(parsed[2]["state"]).to end_with("é")
  end

  it "keeps a line's facts when the rest alone is over the cap" do
    runs.record(id: "approvals.allow/1", judgment: "approvals.allow", questions: [question], state: "x", answers: { "a" => "y" * 40_000 }, session_id: "s1")
    line = store.lines("approvals.allow").first
    expect(line).to include("id" => "approvals.allow/1", "session_id" => "s1", "truncated" => true)
    expect(line).not_to have_key("answers")
  end

  it "leaves a folder that isn't a judgment's alone, and in no one's way" do
    run(session: "gone")
    FileUtils.mkdir_p(File.join(root, "system_one", "runs", "Backup"))
    expect(store.names).to eq(["approvals.allow"])
    expect(store.sweep(days: 14, max_bytes: 1000)).to eq(0)
    expect(store.purge_session("gone")).to eq(1)
    expect(Dir.exist?(File.join(root, "system_one", "runs", "Backup"))).to be(true)
  end

  it "leaves a small state whole, unmarked" do
    run(state: { "command" => "ls" })
    expect(store.lines("approvals.allow").first).to include("state" => { "command" => "ls" })
    expect(store.lines("approvals.allow").first).not_to have_key("truncated")
  end

  it "keeps every line with several writers at once" do
    threads = Array.new(8) { |t| Thread.new { 25.times { |i| run(id: "approvals.allow/#{t}-#{i}") } } }
    threads.each { |thread| join!(thread, "a writer") }
    expect(File.readlines(day_path(today)).size).to eq(200)
    expect(store.lines("approvals.allow").size).to eq(200)
  end

  it "skips a line that doesn't parse" do
    run
    File.open(day_path(today), "a") { |file| file.puts("{broken") }
    expect(store.lines("approvals.allow").size).to eq(1)
  end

  it "refuses a name that isn't safe as a folder" do
    expect { store.lines("../../etc") }.to raise_error(ArgumentError)
    expect { store.append("a/b", { "at" => "2026-11-01" }) }.to raise_error(ArgumentError)
  end

  describe "later lines" do
    it "writes a label, acted and gates to the judgment the id carries" do
      runs.label("toolkit.suggest/9", "kept", by: "user", strength: "strong", question: "toolkit")
      runs.acted("toolkit.suggest/9", "suggested")
      runs.gates("toolkit.suggest/9", rule_listed: true)
      lines = store.lines("toolkit.suggest")
      expect(lines.map { |line| line["kind"] }).to eq(%w[label acted gates])
      expect(lines.first).to include("run_id" => "toolkit.suggest/9", "value" => "kept", "by" => "user", "strength" => "strong", "question" => "toolkit")
    end

    it "does nothing for a judgments log id from before runs, or one naming a path" do
      expect(runs.label("0f0a6f1e-4f6b", "deny", by: "user")).to be(false)
      expect(runs.label("../../x/1", "deny", by: "user")).to be(false)
      expect(store.names).to be_empty
    end

    it "is one warn and a false when it can't be saved" do
      FileUtils.mkdir_p(File.join(root, "system_one"))
      File.write(File.join(root, "system_one", "runs"), "a file in the way")
      expect(Samagotchi::Log).to receive(:warn).with(:system_one, "system_one_run_line_failed", anything).once
      expect(runs.acted("x.y/1", "done")).to be(false)
    end

    it "saves nothing without a store" do
      expect(Samagotchi::SystemOne::Runs.new.acted("x.y/1", "done")).to be(false)
    end
  end

  describe "#sweep" do
    let(:now) { Time.utc(2026, 11, 1, 12) }

    def seed(day, bytes: 10, judgment: "approvals.allow")
      path = day_path(day, judgment: judgment)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "x" * bytes)
    end

    it "deletes day files past the retention by their name, keeping the cutoff day" do
      seed("2026-10-17")
      seed("2026-10-18")
      seed("2026-11-01")
      expect(store.sweep(days: 14, max_bytes: 1000, now: now)).to eq(1)
      expect(File.exist?(day_path("2026-10-17"))).to be(false)
      expect(File.exist?(day_path("2026-10-18"))).to be(true)
    end

    it "keeps everything at days 0, under the cap" do
      seed("2020-01-01")
      expect(store.sweep(days: 0, max_bytes: 1000, now: now)).to eq(0)
      expect(File.exist?(day_path("2020-01-01"))).to be(true)
    end

    it "deletes the oldest over the total cap, across judgments, and never today's" do
      seed("2026-10-30", bytes: 60)
      seed("2026-10-31", bytes: 60, judgment: "toolkit.suggest")
      seed("2026-11-01", bytes: 60)
      seed("2026-11-01", bytes: 60, judgment: "toolkit.suggest")
      expect(store.sweep(days: 0, max_bytes: 130, now: now)).to eq(2)
      expect(File.exist?(day_path("2026-10-30"))).to be(false)
      expect(File.exist?(day_path("2026-10-31", judgment: "toolkit.suggest"))).to be(false)
      expect(File.exist?(day_path("2026-11-01"))).to be(true)
      expect(File.exist?(day_path("2026-11-01", judgment: "toolkit.suggest"))).to be(true)
    end

    it "removes a judgment with no day file left, its versions too" do
      seed("2020-01-01", judgment: "context.candidate")
      File.write(File.join(File.dirname(day_path("x", judgment: "context.candidate")), "versions.jsonl"), "{}\n")
      store.sweep(days: 14, max_bytes: 1000, now: now)
      expect(store.names).to be_empty
    end

    it "is nothing on a machine with no runs" do
      expect(store.sweep(days: 14, max_bytes: 10, now: now)).to eq(0)
    end
  end

  describe "#purge_session" do
    it "takes that session's runs and their later lines, across days, and nobody else's" do
      run(id: "approvals.allow/mine", session: "gone", at: Time.utc(2026, 10, 30, 12))
      run(id: "approvals.allow/other", session: "stays", at: Time.utc(2026, 10, 30, 12))
      runs.label("approvals.allow/mine", "deny", by: "user")
      runs.label("approvals.allow/other", "allow_once", by: "user")
      File.open(day_path("2026-10-30"), "a") { |file| file.puts("{broken") }

      expect(store.purge_session("gone")).to eq(1)
      lines = store.lines("approvals.allow")
      expect(lines.map { |line| line["id"] || line["run_id"] }).to contain_exactly("approvals.allow/other", "approvals.allow/other")
      expect(File.read(day_path("2026-10-30"))).to include("{broken")
      expect(File.stat(day_path("2026-10-30")).mode & 0o777).to eq(0o600)
    end

    it "removes a judgment left with nothing" do
      run(session: "gone")
      store.purge_session("gone")
      expect(store.names).to be_empty
    end

    it "is nothing for a session with no runs" do
      run
      expect(store.purge_session("nobody")).to eq(0)
      expect(store.lines("approvals.allow").size).to eq(1)
    end
  end
end

RSpec.describe "Runs at the session's edges" do
  let(:root) { Dir.mktmpdir("runs-edges") }
  let(:sessions) { File.join(root, "sessions") }
  let(:store) { Samagotchi::SystemOne::RunsStore.new(root) }
  let(:question) { Samagotchi::SystemOne::Question.new(id: "allow", type: :noul, instructions: "Allow?") }

  before { FileUtils.mkdir_p(sessions) }
  after { FileUtils.rm_rf(root) }

  def save_run(session_id)
    Samagotchi::SystemOne::Runs.for_sessions_dir(sessions)
                               .record(id: "approvals.allow/#{session_id}", judgment: "approvals.allow", questions: [question], session_id: session_id)
  end

  def new_session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: root).tap { |s| s.save(state_dir: sessions) }

  it "chi sessions delete purges the session's runs" do
    session = new_session
    save_run(session.id)
    Samagotchi::SessionManager.delete_session(session.id, state_dir: sessions)
    expect(store.names).to be_empty
  end

  it "a session its worker left empty is deleted without reading the runs" do
    session = new_session
    allow(Samagotchi::SessionManager).to receive(:discardable?).and_return(true)
    expect(Samagotchi::SystemOne::Runs).not_to receive(:purge_session)
    Samagotchi::SessionManager.send(:discard_left_session, session.id, state_dir: sessions, default_model: "m")
    expect(File.exist?(Samagotchi::Session.session_file(session.id, state_dir: sessions))).to be(false)
  end

  it "a delete goes on when the purge fails" do
    session = new_session
    allow(Samagotchi::SystemOne::Runs).to receive(:purge_session).and_raise(IOError, "no")
    allow(Samagotchi::Log).to receive(:warn)
    expect(Samagotchi::SessionManager.delete_session(session.id, state_dir: sessions)[:id]).to eq(session.id)
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "session_runs_purge_failed", anything)
  end

  it "the session sweep ages runs out by session.retention_days; deleted sessions' runs stay till then" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("session.retention_days").and_return(14)
    day = File.join(root, "system_one", "runs", "approvals.allow", "2020-01-01.jsonl")
    FileUtils.mkdir_p(File.dirname(day))
    File.write(day, "{}\n")
    save_run("kept")
    Samagotchi::SessionRetention.sweep_if_due(state_dir: sessions)
    expect(File.exist?(day)).to be(false)
    expect(store.lines("approvals.allow").map { |line| line["session_id"] }).to eq(["kept"])
  end

  it "saves nothing under system_one.runs: off, and the sweep still ages what's there" do
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("system_one.runs").and_return("off")
    expect(save_run("x")).to be(false)
    expect(store.names).to be_empty
    day = File.join(root, "system_one", "runs", "approvals.allow", "2020-01-01.jsonl")
    FileUtils.mkdir_p(File.dirname(day))
    File.write(day, "{}\n")
    expect(Samagotchi::SystemOne::Runs.sweep_at(root, days: 14)).to eq(1)
  end

  it "keeps agents off the store: it's in the protected dirs" do
    expect(Samagotchi::Guardrails::ChiDirs.protected).to include(File.join(Samagotchi::Paths.state_dir, "system_one"))
  end
end
