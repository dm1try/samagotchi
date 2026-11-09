# frozen_string_literal: true

require "json"
require "securerandom"
require "stringio"
require "tmpdir"
require "fileutils"
require "spec_helper"
require "samagotchi/schedule_command"
require "samagotchi/session_manager"
require "samagotchi/session_access/dispatch"

# `chi schedule` (docs/scheduling.md): the subcommands, their flags, their exit
# codes and the machine-only contract. The store itself is spec/schedules_spec.rb.
RSpec.describe Samagotchi::ScheduleCommand do
  around do |example|
    Dir.mktmpdir("schedule-command") do |tmp|
      @dir = File.join(File.realpath(tmp), "sessions")
      FileUtils.mkdir_p(@dir)
      example.run
    end
  end

  # A clock the test moves: `due` makes an `every 1m` entry added before it due.
  before { @clock = Time.now }

  let(:schedules) { Samagotchi::Schedules.new(state_dir: @dir, clock: -> { @clock }) }
  let(:every) { Samagotchi::Schedules.recurrence(every: "1m") }
  let(:hourly) { Samagotchi::Schedules.recurrence(every: "1h") }

  def session(scratch: false)
    saved = Samagotchi::Session.new(
      id: SecureRandom.uuid, mode: "assist", model_name: "main:m", working_directory: Dir.tmpdir,
      created_at: @clock.utc.iso8601, updated_at: @clock.utc.iso8601, status: "idle", scratch: scratch,
      messages: [{ role: "user", content: "the routine" }]
    )
    saved.save(state_dir: @dir)
    saved.id
  end

  def due
    @clock += 120
  end

  # @return [Integer, String, String] the exit status, what it printed, what it errored
  def run(*argv, store: schedules)
    out = StringIO.new
    err = StringIO.new
    [described_class.new(argv, stdout: out, stderr: err, schedules: store).run, out.string, err.string]
  end

  describe "add" do
    it "writes the entry and prints what it made" do
      id = session
      status, printed, error = run("add", "--session", id, "--weekday", "1", "--time", "09:00",
                                   "-m", "Audit the queue", "--title", "Audit")
      expect(status).to eq(0), error

      id8 = printed.split.first
      entry = schedules.lookup(id8)
      expect(printed).to eq("#{id8} added: chain · #{id[0, 8]} · Mon 09:00 · " \
                            "next #{Time.iso8601(entry.next_due).localtime.strftime("%Y-%m-%d %H:%M")}\n")
      expect([entry.anchor, entry.head, entry.title, entry.mode, entry.recurrence_words])
        .to eq([id, id, "Audit", Samagotchi::Schedules::CHAIN, "Mon 09:00"])
    end

    it "takes --continues as the target and --mode/--keep-links/--catch-up" do
      id = session
      status, _, error = run("add", "--continues", id, "--every", "30m", "--mode", "same",
                             "--keep-links", "2", "--catch-up", "none", "-m", "Check the build")
      expect(status).to eq(0), error

      entry = schedules.entries.first
      expect([entry.mode, entry.keep_links, entry.catch_up]).to eq(["same", 2, "none"])
    end

    it "refuses an add with no target, a target given as a bare argument, or no prompt" do
      id = session
      status, _, error = run("add", "-m", "x")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule add: add needs --session ID (the session the schedule runs against)\n")

      status, _, error = run("add", id, "-m", "x")
      expect(status).to eq(2)
      expect(error.lines.first).to include("add takes the session with --session ID, not")

      status, _, error = run("add", "--session", id)
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule add: add needs a prompt: -m \"...\"
")
    end

    it "refuses a weekday without a time, two recurrence kinds, a bad or zero interval and --time alone" do
      id = session
      {
        ["--weekday", "1"] => "need a schedule to run against|weekday needs time HH:MM",
        ["--every", "1h", "--weekday", "1", "--time", "09:00"] => "give one of every, weekday or date, not more",
        ["--every", "3x"] => "every needs an interval like 30m, 2h or 1d",
        ["--every", "0m"] => "every must be at least 1s, got 0m",
        ["--every", "1h", "--time", "09:00"] => "time is only for a weekday schedule",
        ["--weekday", "9", "--time", "09:00"] => "weekday must be 1 \\(Mon\\) to 7 \\(Sun\\)",
        ["--weekday", "1abc", "--time", "09:00"] => "weekday must be 1 \\(Mon\\) to 7 \\(Sun\\)",
        ["--every", "1h", "--keep-links", "abc"] => "keep_links must be a number"
      }.each do |argv, reason|
        status, _, error = run("add", "--session", id, *argv, "-m", "x")
        expect(status).to eq(2), argv.join(" ")
        expect(error.lines.first).to match(/#{reason}/), argv.join(" ")
      end
    end

    it "refuses a schedule the chain already has, naming the entry to cancel" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit the queue", recurrence: hourly, title: "Audit")
      status, _, error = run("add", "--session", id, "--every", "1h", "-m", "Audit the queue")
      expect(status).to eq(2), error
      expect(error.lines.first).to include("#{entry.id} already schedules this")
      expect(schedules.entries.size).to eq(1)
    end

    # A person adds it, but it fires from the schedule: a shell line never runs.
    it "refuses a prompt that starts with ! (exit 2)" do
      status, _, error = run("add", "--session", session, "--every", "1h", "-m", "!touch x")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule add: #{Samagotchi::CommandIntake::REFUSED}\n")
      expect(schedules.entries).to be_empty
    end

    it "refuses an empty or oversized prompt, naming the limit (exit 2)" do
      id = session
      status, _, error = run("add", "--session", id, "--every", "1h", "-m", "   ")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule add: add needs a prompt: -m \"...\"\n")

      status, _, error = run("add", "--session", id, "--every", "1h", "-m", "x" * 20_000)
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule add: the prompt is 20000 bytes; the limit is 16 KiB (16384 bytes)\n")
    end

    it "refuses a scratch session at add, and reports a session that is not there (exit 1)" do
      status, _, error = run("add", "--session", session(scratch: true), "--every", "1h", "-m", "x")
      expect(status).to eq(2)
      expect(error.lines.first).to include("a scratch session is deleted")

      status, _, error = run("add", "--session", "zzzzzzzz", "--every", "1h", "-m", "x")
      expect(status).to eq(1)
      expect(error).to eq("no session zzzzzzzz\n")
    end
  end

  describe "list" do
    it "prints one line per enabled schedule, and says there are none" do
      id = session
      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules\n")

      entry = schedules.add(target: id, prompt: "Audit", recurrence: hourly)
      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id}  chain  every 1h  " \
                            "#{Time.iso8601(entry.next_due).localtime.strftime("%Y-%m-%d %H:%M")}  #{id[0, 8]}\n")

      schedules.disable(entry.id)
      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules\n")

      status, printed, error = run("list", "--all")
      expect(status).to eq(0), error
      expect(printed).to include("disabled after 0 failures")
    end

    it "--format json gives the entries for scripts" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", title: "Audit", recurrence: every)
      status, printed, error = run("list", "--format", "json")
      expect(status).to eq(0), error

      rows = JSON.parse(printed)
      expect(rows.size).to eq(1)
      expect([rows.first["id"], rows.first["mode"], rows.first["recurrence_words"]]).to eq([entry.id, "chain", "every 1m"])
      expect(rows.first["skip_window"]).to eq("≈1 h at a 5 min tick")
    end
  end

  describe "show" do
    it "prints the entry, by id or a unique prefix" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit the queue", title: "Audit", recurrence: every)

      status, printed, error = run("show", entry.id[0, 6])
      expect(status).to eq(0), error
      expect(printed).to include("#{entry.id}  Audit", "  anchor: #{id}  head: #{id}  mode: chain",
                                 "  recurrence: every 1m", "  skips: 0 of 12  failures: 0 of 3",
                                 "  prompt: Audit the queue")
    end

    it "exits 1 for an id that is not there and 2 for no id" do
      status, _, error = run("show", "nope")
      expect(status).to eq(1)
      expect(error).to eq("no schedule nope\n")

      status, _, error = run("show")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule show: show needs a schedule id\n")
    end
  end

  describe "tick" do
    it "--dry-run prints would fire and changes nothing" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every)
      due

      status, printed, error = run("tick", "--dry-run")
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id}  would fire  every 1m\n")

      after = schedules.lookup(entry.id)
      expect([after.next_due, after.last_result, after.skips]).to eq([entry.next_due, nil, 0])
    end

    it "fires what is due and prints the outcome" do
      allow(Process).to receive(:spawn).and_return(12_345)
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every)
      due

      status, printed, error = run("tick", "--format", "json")
      expect(status).to eq(0), error
      body = JSON.parse(printed)
      expect(body["locked"]).to be(false)
      outcome = body["outcomes"].first
      expect([outcome["id"], outcome["status"]]).to eq([entry.id, "fired"])
      expect(outcome["detail"]).to match(/\Anew link \h{8}\z/)

      stored = schedules.lookup(entry.id)
      expect(stored.head[0, 8]).to eq(outcome["detail"].split.last)
      expect(Time.iso8601(stored.next_due)).to be > @clock
    end

    it "says so when nothing is due, and when another tick holds the lock" do
      status, printed, error = run("tick")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules due\n")

      schedules.add(target: session, prompt: "Audit", recurrence: hourly)
      status, printed, error = run("tick")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules due\n")

      lock = File.open(schedules.lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose, closed at the end
      lock.flock(File::LOCK_EX)
      due
      status, printed, error = run("tick", "--dry-run")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules due (another tick holds the lock)\n")
      lock.flock(File::LOCK_UN)
      lock.close
    end

    it "reports a skip with its reason and leaves the entry for the next tick" do
      id = session
      FileUtils.mkdir_p(File.join(@dir, id, "input"))
      File.write(File.join(@dir, id, "input", "queued.json"), JSON.generate({ "prompt" => "someone typed here" }))
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every)
      due

      status, printed, error = run("tick")
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id}  skipped  a prompt is queued for it\n")

      stored = schedules.lookup(entry.id)
      expect([stored.skips, stored.next_due, stored.last_result]).to eq([1, entry.next_due, "skipped"])
    end
  end

  describe "run-now, enable, disable and cancel" do
    it "refuses an ambiguous prefix or title with exit 2, naming the matches" do
      fixed = %w[a1b2c3d4e5f6a7b8 a1b2c3d4e5f6a7c9]
      allow(SecureRandom).to receive(:hex).and_wrap_original do |original, length|
        length == 8 ? fixed.shift : original.call(length)
      end
      id = session
      schedules.add(target: id, prompt: "One", recurrence: hourly, title: "Audit")
      schedules.disable("a1b2c3d4e5f6a7b8")
      schedules.add(target: id, prompt: "Two", recurrence: hourly, title: "Audit")

      status, _, error = run("cancel", "a1b2c3")
      expect(status).to eq(2), error
      expect(error).to include("a1b2c3 matches 2 schedules: a1b2c3d4e5f6a7b8, a1b2c3d4e5f6a7c9")

      status, _, error = run("show", "Audit")
      expect(status).to eq(2), error
      expect(error).to include("Audit matches 2 schedules")

      status, _, error = run("run-now", "a1b2c3")
      expect(status).to eq(2), error
      expect(error).to include("a1b2c3 matches 2 schedules")

      status, printed, error = run("disable", "a1b2c3d4e5f6a7c9")
      expect(status).to eq(0), error
      expect(printed).to eq("a1b2c3d4e5f6a7c9 disable: ok\n")
      expect(schedules.entries).to be_empty
      expect(schedules.entries(include_disabled: true).size).to eq(2)
    end

    it "fires an entry whose time is not yet come" do
      allow(Process).to receive(:spawn).and_return(12_345)
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: hourly)

      status, printed, error = run("run-now", entry.id[0, 8])
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id[0, 8]}: fired · new link #{printed.split.last[0, 8]}\n")
      expect(schedules.lookup(entry.id).last_result).to start_with("new link")
    end

    it "disables, re-enables and cancels by id, a prefix or the title" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", title: "Audit", recurrence: every)

      status, printed, error = run("disable", "Audit")
      expect(status).to eq(0), error
      expect(printed).to eq("Audit disable: ok\n")
      expect(schedules.lookup("Audit").enabled).to be(false)
      expect(schedules.entries(include_disabled: true).first.last_result).to eq("disabled")

      status, printed, error = run("enable", entry.id[0, 4])
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id[0, 4]} enable: ok\n")
      expect(schedules.lookup("Audit").enabled).to be(true)

      status, printed, error = run("cancel", entry.id)
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id} cancel: ok\n")
      expect(schedules.entries).to be_empty
    end

    it "exits 1 for an id that is not there and 2 for no id" do
      status, _, error = run("cancel", "gone")
      expect(status).to eq(1)
      expect(error).to eq("no schedule gone\n")

      status, _, error = run("disable")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule disable: disable needs a schedule id\n")
    end
  end

  describe "the subcommand itself" do
    it "prints the usage for no subcommand or --help, and exits 2 for an unknown one" do
      status, printed, = run
      expect(status).to eq(0)
      expect(printed).to start_with("Usage: chi schedule <add|list|show|tick|run-now|enable|disable|cancel> [flags]\n")

      status, printed, error = run("help")
      expect(status).to eq(0), error
      expect(printed).to start_with("Usage: chi schedule")

      status, _, error = run("ls")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule: unknown subcommand ls\n")
    end
  end

  describe "chi --remote NAME schedule …" do
    it "is refused with exit 2: schedules are this machine's (Contract::MACHINE)" do
      remote_err = StringIO.new
      dispatch = Samagotchi::SessionAccess::Dispatch.new(%w[schedule list], remote: "studio")

      expect(Samagotchi::SessionAccess::Contract::MACHINE).to include("schedule")
      expect(dispatch.refusal).to eq("chi schedule runs on this machine only: run it on studio")
      expect(dispatch.run({ "schedule" => ["samagotchi/schedule_command", "ScheduleCommand"] }, stderr: remote_err)).to eq(Samagotchi::CLI::Exit::USAGE)
      expect(remote_err.string).to eq("Error: chi schedule runs on this machine only: run it on studio\n")
    end
  end
end
