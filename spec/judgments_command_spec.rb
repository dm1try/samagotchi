# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "samagotchi/judgments_command"
require "samagotchi/system_one"

RSpec.describe Samagotchi::JudgmentsCommand do
  let(:root) { Dir.mktmpdir("judgments") }
  let(:sessions) { File.join(root, "sessions") }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:store) { Samagotchi::SystemOne::RunsStore.new(root) }
  let(:runs) { Samagotchi::SystemOne::Runs.new(store: store) }
  let(:question) { Samagotchi::SystemOne::Question.new(id: "allow", type: :noul, instructions: "Allow?") }

  after { FileUtils.rm_rf(root) }

  def run_command(*argv) = described_class.new(argv, stdout: stdout, stderr: stderr, sessions_dir: sessions, now: Time.utc(2026, 11, 1, 12)).run

  def save(id, p: 0.95, **fields)
    runs.record(id: "approvals.allow/#{id}", judgment: "approvals.allow", questions: [question], asked: true, served_model: "jev",
                answers: { "allow" => { "type" => "noul", "noul" => p } }, **fields)
  end

  def old_line(id, day)
    path = File.join(root, "system_one", "runs", "approvals.allow", "#{day}.jsonl")
    File.write(path, "#{JSON.generate("kind" => "run", "id" => "approvals.allow/#{id}", "at" => "#{day}T01:00:00Z")}\n")
  end

  it "says when there are no runs" do
    expect(run_command("ls")).to eq(0)
    expect(stdout.string).to eq("No saved runs.\n")
  end

  it "lists each judgment's digests, runs, labels, failures, models and size" do
    save("1")
    save("2", failure: "no_answer")
    runs.label("approvals.allow/1", "deny", by: "user")
    expect(run_command("ls")).to eq(0)
    expect(stdout.string).to match(/\Aapprovals\.allow  digests 1  runs 2  labels 1  failures 1  models jev  \d+(\.\d)? (B|KB)\n\z/)
  end

  it "reports counts, the p histogram and each run's last label by value" do
    save("1", p: 0.95)
    save("2", p: 0.05, truncated: true, test_run: true)
    save("3", p: 1.0, failure: "no_answer")
    runs.label("approvals.allow/1", "deny", by: "user")
    runs.label("approvals.allow/1", "should_have_asked", by: "user", question: "allow")
    runs.label("approvals.allow/1", "allow_once", by: "user", question: "allow")
    runs.acted("approvals.allow/1", "audit")
    expect(run_command("report", "approvals.allow")).to eq(0)
    out = stdout.string
    expect(out).to include("approvals.allow · all kept", "runs 3  asked 3  skipped 0  failures 1  truncated 1  test runs 1",
                           "failures by class: no_answer 1", "allow (noul): 3 with a p", "acted: audit 1")
    expect(out).to match(/0\.0–0\.1\s+1\n/).and match(/0\.9–1\.0\s+2\n/)
    expect(out).to include("allow_once (user) 1").and include("deny (user) 1")
    expect(out).not_to include("should_have_asked")
  end

  it "honours --days by each run's day, and drops a label with no run in the window" do
    save("today")
    old_line("old", "2026-09-01")
    File.open(File.join(root, "system_one", "runs", "approvals.allow", "2026-09-01.jsonl"), "a") do |file|
      file.puts(JSON.generate("kind" => "label", "run_id" => "approvals.allow/old", "value" => "deny", "by" => "user"))
    end
    allow(Time).to receive(:now).and_call_original
    expect(run_command("report", "approvals.allow", "--days", "30")).to eq(0)
    expect(stdout.string).to include("last 30 days", "runs 1").and include("labels: none")
  end

  it "says when a judgment has no runs" do
    expect(run_command("report", "nothing.here")).to eq(0)
    expect(stdout.string).to eq("No runs of nothing.here.\n")
  end

  it "shows a choice's picks" do
    pick = Samagotchi::SystemOne::Question.new(id: "toolkit", type: :choice, instructions: "Which?", criteria: { "a" => "x" })
    runs.record(id: "toolkit.suggest/1", judgment: "toolkit.suggest", questions: [pick],
                answers: { "toolkit" => { "type" => "choice", "choice" => "a", "confidence" => 0.7 } })
    run_command("report", "toolkit.suggest")
    expect(stdout.string).to include("toolkit (choice): 1 with a p, picks a 1").and match(/0\.7–0\.8\s+1\n/)
  end

  it "refuses what it can't use: exit 2" do
    expect(run_command("nope")).to eq(2)
    expect(run_command("report")).to eq(2)
    expect(run_command("report", "../x")).to eq(2)
    expect(run_command("report", "a.b", "--days", "0")).to eq(2)
    expect(run_command("ls", "extra")).to eq(2)
  end

  it "prints its usage" do
    expect(run_command).to eq(0)
    expect(stdout.string).to include("chi judgments ls", "chi judgments report NAME [--days N]")
  end
end
