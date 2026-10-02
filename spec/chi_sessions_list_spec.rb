# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/owner_lock"

# `chi sessions list` as the picker for `chi note` (an Automator dialog,
# a script): --live, --cwd, --format json|tsv. With none of them the output
# is what it always was. It lists the current git project's sessions
# (--scope=all: every project's), so chi runs from a folder in no repo
# unless a spec says otherwise: /work/app (the fixtures' folder) is in none.
RSpec.describe "chi sessions list" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-list") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  # Not a test run itself (a CI runner sets CI): test sessions are hidden
  # from the pickers then.
  let(:env) { { "XDG_STATE_HOME" => xdg_state, "CI" => nil, "RACK_ENV" => nil, "SAMAGOTCHI_ENV" => nil } }
  let(:locks) { [] }

  let(:outside) { Dir.mktmpdir("chi-sessions-list-cwd") }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(xdg_state)
    FileUtils.rm_rf(outside)
  end

  def run_chi(*args, dir: outside)
    super("sessions", "list", *args, env: env, chdir: dir)
  end

  def make(prompt, cwd: "/work/app", live: false, test_run: false, owner: live ? "worker" : nil, parent_id: nil, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd, parent_id: parent_id).tap do |s|
      s.last_prompt = prompt
      s.test_run = test_run
      s.scratch = scratch
      s.save(state_dir: state_dir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: state_dir), kind: owner) if owner
      sleep(0.01) # distinct updated_at
    end
  end

  it "prints the same lines as before with no new flags" do
    session = make("hello there")
    make("a test", test_run: true)

    out, err, status = run_chi

    expect(status.exitstatus).to eq(0), err
    expect(out).to include("#{session.id}  idle      #{" " * 8}  #{Samagotchi::Session.load(session.id, state_dir: state_dir).updated_at}  hello there\n")
    expect(out).to include("  a test [test]\n")
    expect(out).to end_with("\n2 session(s) (sort=updated_at order=desc)\n")
  end

  it "keeps --sort and --order with --format json and --cwd" do
    first = make("first")
    second = make("second")

    newest_first = JSON.parse(run_chi("--format", "json").first).map { |row| row["id"] }
    expect(newest_first).to eq([second.id, first.id])
    oldest_first = JSON.parse(run_chi("--format", "json", "--order", "asc").first).map { |row| row["id"] }
    expect(oldest_first).to eq([first.id, second.id])
    out, = run_chi("--cwd", "/work", "--format", "tsv", "--sort", "created_at", "--order", "asc")
    expect(out.lines.map { |line| line.split("\t").first }).to eq([first.id, second.id])
  end

  it "marks a chi scratch session [scratch]" do
    make("throwaway", scratch: true)

    out, err, status = run_chi

    expect(status.exitstatus).to eq(0), err
    expect(out).to include("  throwaway [scratch]\n")
  end

  it "marks it in the --live, --cwd and --format text listings too; json has scratch" do
    scratch = make("throwaway", scratch: true, owner: "worker")
    plain = make("kept", live: true)

    [%w[--cwd /work], %w[--format text], %w[--live]].each do |args|
      out, err, status = run_chi(*args)
      expect(status.exitstatus).to eq(0), err
      expect(out).to match(/  (app · )?throwaway \[scratch\]\n/), "#{args.join(" ")}: #{out}"
      expect(out).to match(/  (app · )?kept\n/)
    end
    rows = JSON.parse(run_chi("--format", "json").first).to_h { |row| [row["id"], row["scratch"]] }
    expect(rows).to eq(scratch.id => true, plain.id => false)
  end

  def save_context(session, used_tokens, window_tokens)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "analytics.json"),
               JSON.generate("turn_records" => [{ "id" => "t1" }],
                             "context" => { "used_tokens" => used_tokens, "window_tokens" => window_tokens }))
  end

  it "shows how full the context was after the last turn, in the plain and the --live listings; json has ctx_pct" do
    counted = make("counted", live: true)
    save_context(counted, 1234, 10_000)
    scratch = make("throwaway", scratch: true)
    save_context(scratch, 500, 1000)
    unknown = make("no window yet")
    save_context(unknown, 500, nil)

    out, err, status = run_chi
    expect(status.exitstatus).to eq(0), err
    expect(out).to include("#{counted.id}  idle      ctx 12%   ")
    expect(out).to match(/#{scratch.id}  idle      ctx 50%   .*  throwaway \[scratch\]\n/)
    expect(out).to include("#{unknown.id}  idle      #{" " * 8}  ")

    live_out, = run_chi("--live")
    expect(live_out).to include("#{counted.id}  live      ctx 12%   ")

    json, = run_chi("--format", "json", "--scope=all")
    by_id = JSON.parse(json).to_h { |row| [row["id"], row["ctx_pct"]] }
    expect(by_id).to include(counted.id => 12.3, unknown.id => nil)
  end

  it "marks a delegated session with its parent, in the plain and the --live listings; json has parent_id" do
    parent = make("the plan")
    child = make("count the specs", live: true, parent_id: parent.id)

    out, err, status = run_chi
    expect(status.exitstatus).to eq(0), err
    expect(out).to include("#{child.id}  idle      #{" " * 8}  #{Samagotchi::Session.load(child.id, state_dir: state_dir).updated_at}  count the specs  ↳ #{parent.id[0, 8]}\n")
    expect(out).to match(/#{parent.id}  idle .* the plan\n/)

    out, _err, _status = run_chi("--live")
    expect(out).to include("#{child.id}  live      #{" " * 8}  #{Samagotchi::Session.load(child.id, state_dir: state_dir).updated_at}  app · count the specs  ↳ #{parent.id[0, 8]}\n")

    out, _err, _status = run_chi("--format=json")
    by_id = JSON.parse(out).to_h { |row| [row["id"], row["parent_id"]] }
    expect(by_id).to eq(parent.id => nil, child.id => parent.id)
  end

  it "marks a session waiting for an answer, in the plain and the --live listings; json has waiting" do
    asking = make("which file?", live: true)
    approving = make("run it", live: true)
    orphaned = make("crashed while asking")
    { asking => { "id" => "q1", "question" => "Which?" },
      approving => { "id" => "a1", "question" => "execute: x", "kind" => "approval" },
      orphaned => { "id" => "q9", "question" => "Gone?" } }.each do |session, pending|
      s = Samagotchi::Session.load(session.id, state_dir: state_dir)
      s.status = "running"
      s.pending_question = pending
      s.save(state_dir: state_dir)
    end

    out, err, status = run_chi
    expect(status.exitstatus).to eq(0), err
    expect(out).to match(/^#{asking.id}  waiting  .* which file\?\n/)
    expect(out).to match(/^#{approving.id}  waiting  .* run it\n/)
    # A question a dead worker left in the file waits for no one.
    expect(out).to match(/^#{orphaned.id}  running  .* crashed while asking\n/)

    out, _err, _status = run_chi("--live")
    expect(out).to match(/^#{asking.id}  waiting  /)

    out, _err, _status = run_chi("--format", "json")
    by_id = JSON.parse(out).to_h { |row| [row["id"], row.values_at("waiting", "waiting_id")] }
    expect(by_id).to eq(asking.id => %w[question q1], approving.id => %w[approval a1], orphaned.id => [nil, nil])
  end

  it "shows a quoted message without its quote markers" do
    make("> answer:\n> the build failed\n\nsame bug?")

    out, err, status = run_chi

    expect(status.exitstatus).to eq(0), err
    expect(out).to include("  answer: the build failed same bug?\n")
  end

  def write_recap(session, text)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "recap.json"), JSON.generate(text: text, covered: 2))
  end

  it "shows a saved recap's first sentence in place of the last prompt, in the text output only" do
    recapped = make("fix it", live: true)
    plain = make("hello there", live: true)
    write_recap(recapped, "The user was fixing the login page for the new theme, and the tests. It works now.")

    out, err, status = run_chi
    expect(status.exitstatus).to eq(0), err
    line = out.lines.find { |l| l.start_with?(recapped.id) }
    expect(line).to end_with("  Fixing the login page for the new theme, and the tests.\n")
    expect(out.lines.find { |l| l.start_with?(plain.id) }).to end_with("  hello there\n")

    live_out = run_chi("--live").first
    expect(live_out.lines.find { |l| l.start_with?(recapped.id) })
      .to end_with("  app · Fixing the login page for the new theme, and the test…\n")
    expect(live_out.lines.find { |l| l.start_with?(plain.id) }).to end_with("  app · hello there\n")

    expect(run_chi("--live", "--format", "tsv").first).to include("#{recapped.id}\tapp · fix it\n")
    expect(JSON.parse(run_chi("--live", "--format", "json").first).find { |r| r["id"] == recapped.id })
      .to include("desc" => "app · fix it")
  end

  it "cuts a long recap to 60 characters, as it does a prompt" do
    session = make("x")
    write_recap(session, "Checking #{"word " * 30}.")

    line = run_chi.first.lines.find { |l| l.start_with?(session.id) }
    expect(line.chomp.split("  ").last).to eq("Checking #{"word " * 30}"[0, 60])
  end

  it "--live --format tsv: id<TAB>description per live session, for choose from list + cut -f1" do
    live = make("fix the login page", live: true)
    make("stopped one")
    make("a live test", live: true, test_run: true)

    out, err, status = run_chi("--live", "--format", "tsv")

    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("#{live.id}\tapp · fix the login page\n")
  end

  it "--live in a test run (SAMAGOTCHI_ENV=test) lists its test sessions, marked [test]" do
    live = make("a live test", live: true, test_run: true)

    out, err, status = run_chi("--live")
    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("No sessions.\n")

    env["SAMAGOTCHI_ENV"] = "test"
    out, err, status = run_chi("--live")
    expect(status.exitstatus).to eq(0), err
    expect(out).to start_with("#{live.id}  live      ")
    expect(out).to include("a live test [test]\n")
    expect(out).to end_with("\n1 session(s)\n")
  end

  it "--format json: one object per session" do
    live = make("fix it", cwd: "/work/app", live: true)

    out, err, status = run_chi("--live", "--format=json", "--cwd", "/work")

    expect(status.exitstatus).to eq(0), err
    expect(JSON.parse(out)).to eq([{ "id" => live.id, "short_id" => live.id[0, 8], "desc" => "app · fix it",
                                     "cwd" => "/work/app", "project" => nil, "updated_at" => Samagotchi::Session.load(live.id, state_dir: state_dir).updated_at,
                                     "live" => true, "busy" => false, "owner" => "worker", "recap" => nil, "parent_id" => nil,
                                     "archived" => false, "scratch" => false, "ctx_pct" => nil, "waiting" => nil,
                                     "waiting_id" => nil }])
  end

  it "--format json: each session's recap, its first sentence; the tsv lines don't change" do
    live = make("fix it", live: true)
    FileUtils.mkdir_p(Samagotchi::Session.session_dir(live.id, state_dir: state_dir))
    File.write(File.join(Samagotchi::Session.session_dir(live.id, state_dir: state_dir), "recap.json"),
               JSON.generate(text: "We fixed the login. Then the tests.", covered: 2))

    expect(JSON.parse(run_chi("--live", "--format", "json").first).first).to include("recap" => "We fixed the login.")
    expect(run_chi("--live", "--format", "tsv").first).to eq("#{live.id}\tapp · fix it\n")
  end

  it "--format json: owner is worker, tui (a chi REPL) or null; the text and tsv lines don't change" do
    stopped = make("stopped")
    repl = make("in a repl", owner: "tui")
    live = make("live", live: true)

    out, err, status = run_chi("--format", "json")

    expect(status.exitstatus).to eq(0), err
    expect(JSON.parse(out).to_h { |row| [row["id"], row["owner"]] }).to eq(live.id => "worker", repl.id => "tui", stopped.id => nil)
    expect(run_chi("--format", "tsv").first.lines).to eq(["#{live.id}\tapp · live\n", "#{repl.id}\tapp · in a repl\n",
                                                          "#{stopped.id}\tapp · stopped\n"])
    expect(run_chi("--cwd", "/work").first).not_to include("tui", "worker")
  end

  it "prints an empty JSON array when nothing matches" do
    out, _err, status = run_chi("--live", "--format", "json")

    expect(status.exitstatus).to eq(0)
    expect(JSON.parse(out)).to eq([])
  end

  it "--live defaults to 10 sessions; --limit changes that" do
    12.times { |i| make("p#{i}", live: true) }

    expect(run_chi("--live", "--format", "tsv").first.lines.size).to eq(10)
    expect(run_chi("--live", "--format", "tsv", "--limit", "3").first.lines.size).to eq(3)
  end

  it "refuses an unknown format" do
    _out, err, status = run_chi("--format", "yaml")

    expect(status.exitstatus).to eq(2)
    expect(err).to include("--format text|json|tsv")
  end

  it "lists the flags in the help" do
    out, = Open3.capture3(env, RbConfig.ruby, chi, "sessions", "--help", stdin_data: "")
    expect(out).to include("--live", "--cwd PATH", "--format text|json|tsv", "--scope=all")
  end

  describe "the project scope" do
    def git(*args)
      out, status = Open3.capture2e("git", "-c", "user.name=x", "-c", "user.email=x@x",
                                    "-c", "init.defaultBranch=main", *args)
      raise "git #{args.join(" ")} failed: #{out}" unless status.success?
    end

    let(:root) { File.realpath(outside) }
    let(:alpha) do
      File.join(root, "alpha").tap do |dir|
        git("init", "-q", dir)
        git("-C", dir, "commit", "-q", "--allow-empty", "-m", "i")
      end
    end
    let(:worktree) { File.join(root, "alpha-wt").tap { |dir| git("-C", alpha, "worktree", "add", "-q", "-b", "wt", dir) } }
    let(:beta) { File.join(root, "beta").tap { |dir| git("init", "-q", dir) } }
    let!(:sessions) do
      { a: make("in alpha", cwd: alpha, live: true), wt: make("in the worktree", cwd: worktree),
        b: make("in beta", cwd: beta, live: true), plain: make("plain", cwd: "/work/app") }
    end

    def ids(out) = out.lines.filter_map { |line| line[/\A[0-9a-f-]{36}/] }

    it "lists this project's sessions from the repo or its worktree, and says so in the footer" do
      [alpha, worktree, File.join(alpha, ".git", "..")].each do |dir|
        out, err, status = run_chi(dir: dir)

        expect(status.exitstatus).to eq(0), err
        expect(ids(out)).to eq([sessions[:wt].id, sessions[:a].id])
        expect(out).to end_with("\n2 session(s) in alpha (--scope=all: every project)\n")
      end
    end

    it "--scope=all (either form) and a folder in no repo list every session, with the old footer" do
      [run_chi("--scope=all", dir: alpha), run_chi("--scope", "all", dir: alpha), run_chi].each do |out, err, _|
        expect(ids(out).size).to eq(4), err
        expect(out).to end_with("\n4 session(s) (sort=updated_at order=desc)\n")
      end
    end

    it "scopes --live and --format too; --cwd replaces the project; json has the project" do
      expect(run_chi("--live", "--format", "tsv", dir: alpha).first.lines.map { |l| l.split("\t").first }).to eq([sessions[:a].id])
      expect(run_chi("--live", "--format", "tsv", "--scope=all", dir: alpha).first.lines.size).to eq(2)
      expect(run_chi("--live", dir: alpha).first).to end_with("\n1 session(s) in alpha (--scope=all: every project)\n")
      expect(ids(run_chi("--cwd", beta, dir: alpha).first)).to eq([sessions[:b].id])

      rows = JSON.parse(run_chi("--format", "json", "--scope=all", dir: alpha).first)
      expect(rows.to_h { |row| [row["id"], row["project"]] })
        .to eq(sessions[:a].id => alpha, sessions[:wt].id => alpha, sessions[:b].id => beta, sessions[:plain].id => nil)
    end

    it "shows the recap in the project's listing too" do
      write_recap(sessions[:a], "The user and assistant explored the alpha repo.")

      expect(run_chi(dir: alpha).first).to include("#{sessions[:a].id}  ", "  Explored the alpha repo.\n")
    end

    it "says so when the project has no sessions yet" do
      empty = File.join(root, "gamma").tap { |dir| git("init", "-q", dir) }

      expect(run_chi(dir: empty).first).to eq("0 session(s) in gamma (--scope=all: every project)\n")
    end

    it "refuses an unknown scope" do
      _out, err, status = run_chi("--scope=mine", dir: alpha)

      expect(status.exitstatus).to eq(2)
      expect(err).to include("--scope=project|all")
    end

    it "leaves chi note --all global: every live session, whichever project chi runs in" do
      _out, err, status = Open3.capture3(env, RbConfig.ruby, chi, "note", "--all", "-m", "heads up", stdin_data: "", chdir: alpha)

      expect(status.exitstatus).to eq(0), err
      notes = %i[a b].map do |key|
        Dir.glob(File.join(Samagotchi::Session.session_dir(sessions[key].id, state_dir: state_dir), "notes", "*.json")).size
      end
      expect(notes).to eq([1, 1])
    end
  end
end
