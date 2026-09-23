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
# is what it always was.
RSpec.describe "chi sessions list" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-list") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  let(:env) { { "XDG_STATE_HOME" => xdg_state } }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(xdg_state)
  end

  def run_chi(*args)
    Open3.capture3(env, RbConfig.ruby, chi, "sessions", "list", *args, stdin_data: "")
  end

  def make(prompt, cwd: "/work/app", live: false, test_run: false, owner: live ? "worker" : nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
      s.last_prompt = prompt
      s.test_run = test_run
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
    expect(out).to include("#{session.id}  idle      #{Samagotchi::Session.load(session.id, state_dir: state_dir).updated_at}  hello there\n")
    expect(out).to include("  a test [test]\n")
    expect(out).to end_with("\n2 session(s) (sort=updated_at order=desc)\n")
  end

  it "--live --format tsv: id<TAB>description per live session, for choose from list + cut -f1" do
    live = make("fix the login page", live: true)
    make("stopped one")
    make("a live test", live: true, test_run: true)

    out, err, status = run_chi("--live", "--format", "tsv")

    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("#{live.id}\tapp · fix the login page\n")
  end

  it "--format json: one object per session" do
    live = make("fix it", cwd: "/work/app", live: true)

    out, err, status = run_chi("--live", "--format=json", "--cwd", "/work")

    expect(status.exitstatus).to eq(0), err
    expect(JSON.parse(out)).to eq([{ "id" => live.id, "short_id" => live.id[0, 8], "desc" => "app · fix it",
                                     "cwd" => "/work/app", "updated_at" => Samagotchi::Session.load(live.id, state_dir: state_dir).updated_at,
                                     "live" => true, "busy" => false, "owner" => "worker" }])
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

    expect(status.exitstatus).to eq(1)
    expect(err).to include("--format text|json|tsv")
  end

  it "lists the flags in the help" do
    out, = Open3.capture3(env, RbConfig.ruby, chi, "sessions", "--help", stdin_data: "")
    expect(out).to include("--live", "--cwd PATH", "--format text|json|tsv")
  end
end
