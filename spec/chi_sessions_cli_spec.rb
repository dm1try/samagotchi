# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session"

# `chi sessions` through bin/chi: help, each subcommand's flags and usage errors,
# list's plain path, stop's usage and prune/clean, pinned before the command
# moved out of bin/chi. The other paths have their own specs
# (chi_sessions_list/stop/clean/archive_spec, session_delete_command_spec).
RSpec.describe "chi sessions (CLI)" do
  let(:xdg_state) { Dir.mktmpdir("chi-sessions-cli") }
  let(:outside) { Dir.mktmpdir("chi-sessions-cli-cwd") }
  let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }
  # Not a test run itself (a CI runner sets CI): the test-run flag matters here.
  let(:env) { { "XDG_STATE_HOME" => xdg_state, "CI" => nil, "RACK_ENV" => nil, "SAMAGOTCHI_ENV" => nil } }

  let(:usage) do
    <<~TEXT
      Usage: chi sessions <list|stop|archive|unarchive|delete|prune|clean> [options]
        list [--sort updated_at|created_at] [--order desc|asc] [--limit N]
             [--live] [--cwd PATH] [--format text|json|tsv] [--archived]
             --live: sessions a worker runs now (the ones chi note reaches), 10 unless --limit
             --cwd PATH: sessions in PATH or below; json/tsv (id<TAB>description) are for scripts
             [--scope=all]: every project's sessions; by default only this git project's (all outside a repo)
             --archived: archived sessions too (marked [archived]; json: archived: true)
        stop ID...   # stop each session's worker (IDs or unique prefixes); chi --resume ID then starts a fresh one
        archive ID...   # hide sessions (and their delegates) from every list and keep them for good; unarchive ID... brings them back
        delete [--force] ID...   # delete sessions for good (IDs or unique prefixes); --force stops a live worker first
        prune [--dry-run] [--days N] [--keep N] [--keep-status running,...] [--test-only]
        clean [--dry-run] [--days N]   # test sessions (SAMAGOTCHI_ENV=test, CI) and leftover chi scratch ones: all of them, or those older than N days
      Defaults: days=14 keep=500 keep_status=none (config: session.retention_days, session.max_count, session.keep_status)
    TEXT
  end
  let(:stop_usage) { "Usage: chi sessions stop ID...\n" }

  after do
    FileUtils.rm_rf(xdg_state)
    FileUtils.rm_rf(outside)
  end

  def run_chi(*args)
    out, err, status = super("sessions", *args, env: env, chdir: outside)
    [out, err, status.exitstatus]
  end

  def make(prompt, days_old: 0, test_run: false, status: "idle")
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app", test_run: test_run).tap do |s|
      s.messages = [{ role: "user", content: prompt }, { role: "model", content: "ok" }]
      s.last_prompt = prompt
      s.status = status
      s.save(state_dir: state_dir)
      sleep(0.01) # distinct created_at / updated_at
      next if days_old.zero?

      path = File.join(state_dir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - days_old * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
    end
  end

  def exists?(session) = File.exist?(File.join(state_dir, "#{session.id}.json"))
  def ids_in(out) = out.lines.filter_map { |line| line[/\A(\h{8}-\h{4}-\h{4}-\h{4}-\h{12})  /, 1] }

  it "prints the usage on stdout for no argument, -h, --help and help" do
    [[], ["-h"], ["--help"], ["help"]].each do |args|
      expect(run_chi(*args)).to eq([usage, "", 0]), args.inspect
    end
  end

  # A usage error exits 2 with the usage on stderr, as every chi command's.
  it "refuses an unknown subcommand with the usage (exit 2)" do
    expect(run_chi("nope")).to eq(["", "chi sessions: unknown subcommand nope\n#{usage}", 2])
  end

  # The subcommand must come first; a flag before it is taken as one.
  it "refuses a flag before the subcommand" do
    expect(run_chi("--dry-run", "prune")).to eq(["", "chi sessions: unknown subcommand --dry-run\n#{usage}", 2])
  end

  it "list sorts by created_at ascending and says so in the footer, and --limit=N cuts it" do
    first = make("first")
    second = make("second")

    out, err, code = run_chi("list", "--sort", "created_at", "--order", "asc")
    expect([err, code]).to eq(["", 0])
    expect(ids_in(out)).to eq([first.id, second.id])
    expect(out).to end_with("\n2 session(s) (sort=created_at order=asc)\n")

    out, err, code = run_chi("list", "--limit=1")
    expect([err, code]).to eq(["", 0])
    expect(ids_in(out)).to eq([second.id])
    expect(out).to end_with("\n1 session(s) (sort=updated_at order=desc)\n")
  end

  it "list refuses an unknown flag, a value flag with no value and an argument (exit 2)" do
    expect(run_chi("list", "--bogus")).to eq(["", "chi sessions list: unknown option --bogus\n#{usage}", 2])
    expect(run_chi("list", "--limit")).to eq(["", "chi sessions list: --limit needs a value\n#{usage}", 2])
    expect(run_chi("list", "extra")).to eq(["", "chi sessions list: unknown option extra\n#{usage}", 2])
  end

  # The desktop helper (desktop/macos/ChiRunner.swift) runs these two.
  it "list answers the desktop helper's argv with JSON" do
    session = make("hello")

    [%w[list --live --scope=all --format json], %w[list --limit 20 --scope=all --format json]].each do |args|
      out, err, code = run_chi(*args)
      expect([err, code]).to eq(["", 0]), args.inspect
      expect(JSON.parse(out).map { |row| row["id"] }).to eq(args.include?("--live") ? [] : [session.id])
    end
  end

  it "stop refuses a dash argument or no ids with its usage (exit 2)" do
    expect(run_chi("stop", "--force")).to eq(["", "chi sessions stop: unknown option --force\n#{stop_usage}", 2])
    expect(run_chi("stop")).to eq(["", "chi sessions stop: give session ids\n#{stop_usage}", 2])
  end

  it "prune and clean refuse an unknown flag, a missing value and an argument (exit 2), deleting nothing" do
    old = make("old", days_old: 30)

    expect(run_chi("prune", "--bogus")).to eq(["", "chi sessions prune: unknown option --bogus\n#{usage}", 2])
    expect(run_chi("prune", "--days")).to eq(["", "chi sessions prune: --days needs a value\n#{usage}", 2])
    expect(run_chi("prune", "--all")).to eq(["", "chi sessions prune: unknown option --all\n#{usage}", 2])
    expect(run_chi("clean", "--keep", "1")).to eq(["", "chi sessions clean: unknown option --keep\n#{usage}", 2])
    expect(run_chi("clean", "old")).to eq(["", "chi sessions clean: unknown option old\n#{usage}", 2])
    expect(exists?(old)).to be(true)
  end

  it "prune --days N deletes the older sessions, with no dry-run tail" do
    old = make("old", days_old: 30)
    fresh = make("fresh")

    expect(run_chi("prune", "--days", "1")).to eq(["Deleted 1 sessions (kept 1, skipped 0)\n  #{old.id}\n", "", 0])
    expect([exists?(old), exists?(fresh)]).to eq([false, true])
  end

  it "prune --keep N deletes past the newest N" do
    oldest = make("oldest")
    middle = make("middle")
    newest = make("newest")

    out, err, code = run_chi("prune", "--keep", "1")

    expect([err, code]).to eq(["", 0])
    expect(out).to eq("Deleted 2 sessions (kept 1, skipped 0)\n  #{middle.id}\n  #{oldest.id}\n")
    expect(exists?(newest)).to be(true)
  end

  it "prune --dry-run lists, keeps, and adds the tail only when something would go" do
    old = make("old", days_old: 30)

    expect(run_chi("prune", "--dry-run", "--days", "1"))
      .to eq(["Would delete 1 sessions (kept 0, skipped 0)\n  #{old.id}\n\nRun without --dry-run to delete.\n", "", 0])
    expect(run_chi("prune", "--dry-run", "--days", "60")).to eq(["Would delete 0 sessions (kept 1, skipped 0)\n", "", 0])
    expect(exists?(old)).to be(true)
  end

  it "prune --test-only and --test take only the aged test sessions" do
    %w[--test-only --test].each do |flag|
      old_test = make("old test", days_old: 30, test_run: true)
      old_real = make("old real", days_old: 30)

      out, err, code = run_chi("prune", flag)

      expect([out, err, code]).to eq(["Deleted 1 sessions (kept 0, skipped 0)\n  #{old_test.id}\n", "", 0]), flag
      expect([exists?(old_test), exists?(old_real)]).to eq([false, true])
      FileUtils.rm_rf(state_dir)
    end
  end

  it "clean --all takes aged sessions of any kind; clean alone only test ones" do
    old_test = make("old test", days_old: 30, test_run: true)
    old_real = make("old real", days_old: 30)
    fresh_real = make("fresh real")

    out, err, code = run_chi("clean", "--dry-run")
    expect([err, code]).to eq(["", 0])
    expect(out).to eq("Would delete 1 sessions (kept 0, skipped 0)\n  #{old_test.id}\n\nRun without --dry-run to delete.\n")

    out, err, code = run_chi("clean", "--all")
    expect([err, code]).to eq(["", 0])
    expect(out.lines.first).to eq("Deleted 2 sessions (kept 1, skipped 0)\n")
    expect([exists?(old_test), exists?(old_real), exists?(fresh_real)]).to eq([false, false, true])
  end

  it "prune --keep-status keeps the aged sessions in that status" do
    idle = make("idle", days_old: 30, status: "idle")
    completed = make("done", days_old: 30, status: "completed")

    expect(run_chi("prune", "--keep-status", "idle", "--days", "1"))
      .to eq(["Deleted 1 sessions (kept 1, skipped 0)\n  #{completed.id}\n", "", 0])
    expect([exists?(idle), exists?(completed)]).to eq([true, false])
  end

  # quirk: --days=abc is 0, and 0 days turns the age limit off
  it "prune --days=abc keeps an aged session that --days=1 deletes" do
    old = make("old", days_old: 30)

    expect(run_chi("prune", "--days=abc")).to eq(["Deleted 0 sessions (kept 1, skipped 0)\n", "", 0])
    expect(exists?(old)).to be(true)
    expect(run_chi("prune", "--days=1")).to eq(["Deleted 1 sessions (kept 0, skipped 0)\n  #{old.id}\n", "", 0])
  end
end
