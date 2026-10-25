# frozen_string_literal: true

require "digest"
require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/guardrails_command"
require "samagotchi/system_one"

# `chi guardrails replay`: the asks this machine's sessions already answered,
# judged and logged so a rule's record starts with real decisions. The client
# is injected (a FakeBackend), so no spec reaches a host.
RSpec.describe Samagotchi::GuardrailsCommand do
  S1 = Samagotchi::SystemOne

  # The judgment System 1 gives each rule: shell-touches-chi gets no answer at
  # all, which the log records with p null.
  NOULS = { "git-push" => 0.97, "memory-remove" => 0.40, "shell-touches-chi" => nil }.freeze
  SCOPES = %w[once session repo rule].freeze

  let(:tmpdir) { File.realpath(Dir.mktmpdir("guardrails-replay")) }
  let(:sessions_dir) { File.join(tmpdir, "samagotchi", "sessions") }
  let(:log) { S1::Log.new(dir: File.join(tmpdir, "samagotchi", "guardrails")) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:states) { [] }
  let(:client) do
    S1::Client.new(backend: S1::FakeBackend.new do |state, questions|
      states << state
      noul = NOULS[state["rule"]]
      noul.nil? ? {} : questions.to_h { |question| [question.id, S1::Answer.new(id: question.id, type: :noul, noul: noul)] }
    end, mode: "audit", host: "splash", model: "judge-model")
  end

  # `judge:` is the client the command judges with: the fake by default, nil
  # for the "config names no client" case.
  def run(argv, judge: client)
    described_class.new(argv, stdout: out, stderr: err, client: judge, sessions_dir: sessions_dir, log: log).run
  end

  def approval(rule, scopes: SCOPES)
    { "tool" => "execute", "command" => "git push origin main", "cwd" => tmpdir, "repo_name" => "samagotchi",
      "branch" => "main", "rule" => rule, "source" => "bundle guardrails", "reason" => "the rule asked",
      "scopes" => scopes }
  end

  # A question card as the CardStore saves it: the approval, and either an
  # answer, a cancellation, or neither.
  def question(id, rule, answer: nil, cancelled: false, scopes: SCOPES, user_only: nil)
    entry = { "type" => "question", "in_turn" => true, "turns" => 1,
              "pending_question" => { "id" => id, "question" => "Approve tool call?",
                                      "options" => ["Allow once", "Allow this call for the session", "Deny"],
                                      "approval" => approval(rule, scopes: scopes), "status" => "pending",
                                      "created_at" => "2026-10-20T10:00:00+02:00" } }
    entry["pending_question"]["user_only"] = true if user_only
    entry["answer"] = answer if answer
    entry["cancelled"] = true if cancelled
    entry
  end

  def answer(index, by: nil)
    { "id" => "q", "selected" => [], "freeform" => nil, "selected_indices" => [index], "by" => by }
  end

  # A session folder, its session file (with a title, and its own
  # parent_answers when given) and its cards.json. @return the session's id.
  def session(entries, title: nil, parent_answers: nil)
    saved = Samagotchi::Session.new_session(mode: "assist", model_name: "spec-model", working_directory: tmpdir)
    saved.title = title if title
    saved.parent_answers = parent_answers if parent_answers
    saved.save(state_dir: sessions_dir)
    dir = Samagotchi::Session.session_dir(saved.id, state_dir: sessions_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "cards.json"), JSON.generate({ "version" => 1, "turns" => 3, "entries" => entries }))
    saved.id
  end

  # Every shape a cards file holds: an allow at "once", a wider allow, a deny,
  # a cancelled ask, a parent agent's answer, a relay card with no approval,
  # an ask never answered, a plain card — plus a session whose sidecar does
  # not parse.
  def fixture
    relay = { "type" => "question", "in_turn" => true, "turns" => 2,
              "pending_question" => { "id" => "q-relay", "question" => "a child session asks",
                                      "options" => ["Allow once", "Deny"],
                                      "relay" => { "session_id" => "child", "question_id" => "q-relay" },
                                      "created_at" => "2026-10-20T11:00:00+02:00" } }
    @session_id = session([
      question("q-once", "git-push", answer: answer(0)),
      question("q-wide", "git-push", answer: answer(2)),
      question("q-deny", "git-push", answer: answer(4)),
      question("q-cancel", "git-push", cancelled: true),
      question("q-parent", "git-push", answer: answer(0, by: "parent_agent")),
      question("q-open", "git-push"),
      relay,
      { "type" => "card", "id" => "c1", "title" => "A card is not an ask" },
      question("q-low", "memory-remove", answer: answer(0)),
      question("q-none", "shell-touches-chi", answer: answer(0))
    ], title: "work on P2b")
    broken = File.join(sessions_dir, "bbbb2222-2222-2222-2222-222222222222")
    FileUtils.mkdir_p(broken)
    File.write(File.join(broken, "cards.json"), "{not json at all")
    @session_id
  end

  def lines = log.entries

  it "writes a judgment and a label line for every ask the user answered" do
    fixture
    expect(run(["replay"])).to eq(0)

    entries = lines
    expect(entries.map { |entry| entry["question_id"] }).to eq(%w[q-once q-wide q-deny q-cancel q-low q-none])
    expect(entries.map { |entry| entry["answer"] }).to eq(%w[allow_once allow_wide deny none allow_once allow_once])
    first = entries.first
    expect(first).to include("kind" => "judgment", "decision" => "replay", "origin" => "replay", "rule" => "git-push",
                             "source" => "bundle guardrails", "tool" => "execute", "model" => "judge-model",
                             "threshold" => 0.8, "p" => 0.97, "asked_at" => "2026-10-20T10:00:00+02:00")
    expect(first["session_id"]).to eq(@session_id)
    expect(first["repo_name"]).to eq("samagotchi")
    expect(first["call"]).to eq("git push origin main")
    expect(first["call_digest"]).to eq(Digest::SHA256.hexdigest("git push origin main"))
    expect(first["latency_ms"]).to be_a(Integer)
    # A judgment that never came is logged too, with p null.
    expect(entries.last["p"]).to be_nil
    expect(entries.last["rule"]).to eq("shell-touches-chi")
  end

  it "writes the label as its own line keyed by the judgment id" do
    fixture
    run(["replay"])
    raw = File.readlines(File.join(tmpdir, "samagotchi", "guardrails", "judgments.jsonl")).map { |line| JSON.parse(line) }
    expect(raw.map { |line| line["kind"] }).to eq(%w[judgment label] * 6)
    expect(raw.last["id"]).to eq(raw[-2]["id"])
    expect(raw.select { |line| line["kind"] == "label" }.map { |line| line["answer"] }).to eq(%w[allow_once allow_wide deny none allow_once allow_once])
  end

  it "skips a parent agent's answer, a relay card and an unanswered ask" do
    fixture
    run(["replay"])
    expect(lines.map { |entry| entry["question_id"] }).not_to include("q-parent", "q-relay", "q-open")
    expect(out.string).to include("skipped: 1 answered by a parent agent, 1 no approval card, 1 unanswered, 1 unreadable cards file")
    expect(err.string).to include("cards.json: unreadable cards")
  end

  it "prints the per-rule table sorted by count, then the totals" do
    fixture
    run(["replay"])
    rows = out.string.lines.reject { |line| line.start_with?("-") }.first(5).map { |line| line.split(/\s+/) }
    expect(rows[0]).to eq(%w[rule asks allowed denied auto false_allows no_judgment])
    expect(rows[1]).to eq(%w[git-push 4 2 1 2 1 0])
    expect(rows[2]).to eq(%w[memory-remove 1 1 0 0 0 0])
    expect(rows[3]).to eq(%w[shell-touches-chi 1 1 0 0 0 1])
    expect(rows[4]).to eq(%w[total 6 4 1 2 1 1])
    expect(out.string).to include("6 asks replayed from 1 session · threshold 0.8 · model judge-model")
  end

  it "counts auto and false allows against --threshold" do
    fixture
    run(["replay", "--threshold", "0.98"])
    rows = out.string.lines.reject { |line| line.start_with?("-") }
    expect(rows[1].split(/\s+/)[1..]).to eq(%w[4 2 1 0 0 0])
    expect(out.string).to include("threshold 0.98")
  end

  it "adds nothing on a second run: the question ids are already logged" do
    fixture
    run(["replay"])
    before = lines.size
    run(["replay"])
    expect(lines.size).to eq(before)
    expect(out.string).to include("0 asks replayed from 0 sessions")
    expect(out.string).to include("6 already replayed")
  end

  it "judges but writes nothing with --dry-run" do
    fixture
    expect(run(["replay", "--dry-run"])).to eq(0)
    expect(File.exist?(File.join(tmpdir, "samagotchi", "guardrails", "judgments.jsonl"))).to be(false)
    expect(out.string).to include("6 asks replayed")
    expect(out.string).to include("dry run: nothing was written")
  end

  it "reads the sessions from $XDG_STATE_HOME when no dir is given" do
    fixture
    with_env("XDG_STATE_HOME" => tmpdir) do
      expect(described_class.new(["replay"], stdout: out, stderr: err, client: client).run).to eq(0)
      expect(out.string).to include("6 asks replayed")
    end
  end

  it "sends the session's title in the ask's state" do
    fixture
    run(["replay"])
    titled = states.find { |state| state["session"] == "work on P2b" }
    expect(titled).to include("rule" => "git-push", "command" => "git push origin main", "repo_name" => "samagotchi")
  end

  it "exits 2 saying what to set when there is no client" do
    fixture
    expect(run(["replay"], judge: nil)).to eq(2)
    expect(err.string).to include("guardrails.system_one.mode")
    expect(out.string).to eq("")
    expect(lines).to eq([])
  end

  it "refuses an unknown subcommand, a bad --threshold and a stray argument" do
    expect(run(["frobnicate"])).to eq(2)
    expect(run(["replay", "--threshold", "abc"])).to eq(2)
    expect(err.string).to include("--threshold takes a number")
    expect(run(["replay", "--dry-run", "extra"])).to eq(2)
  end

  # A parent agent's answer is not the user's. Only its deny is a label, and
  # only where the parent could have allowed: the ask is not user-only, and
  # the session's parent level permits a "permit" option.
  describe "a parent agent's answer" do
    DENY_INDEX = 4

    it "judges and labels a parent's deny when the parent could have allowed" do
      session([question("q-parent-deny", "git-push", answer: answer(DENY_INDEX, by: "parent_agent"))])
      expect(run(["replay"])).to eq(0)
      entries = lines
      expect(entries.size).to eq(1)
      expect(entries.first).to include("kind" => "judgment", "question_id" => "q-parent-deny", "decision" => "replay",
                                       "rule" => "git-push", "p" => 0.97, "answer" => "deny")
    end

    it "skips a parent's allow: it is not the user's decision" do
      session([question("q-parent-allow", "git-push", answer: answer(0, by: "parent_agent"))])
      run(["replay"])
      expect(lines).to eq([])
      expect(out.string).to include("1 answered by a parent agent")
    end

    it "skips a parent's deny on an ask only the user may answer" do
      session([question("q-parent-user-only", "chi-config", answer: answer(DENY_INDEX, by: "parent_agent"), user_only: true)])
      run(["replay"])
      expect(lines).to eq([])
      expect(out.string).to include("1 answered by a parent that could not allow")
    end

    it "skips a parent's deny when the session's parent level forbids permitting" do
      session([question("q-parent-hard", "git-push", answer: answer(DENY_INDEX, by: "parent_agent"))], parent_answers: "hard")
      run(["replay"])
      expect(lines).to eq([])
      expect(out.string).to include("1 answered by a parent that could not allow")
    end

    it "skips a parent's deny when the card has no session file to read the level from" do
      dir = File.join(sessions_dir, "cccc3333-3333-3333-3333-333333333333")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "cards.json"),
                 JSON.generate({ "version" => 1, "turns" => 1,
                                 "entries" => [question("q-no-session", "git-push", answer: answer(DENY_INDEX, by: "parent_agent"))] }))
      run(["replay"])
      expect(lines).to eq([])
      expect(out.string).to include("1 answered by a parent that could not allow")
    end
  end
end
