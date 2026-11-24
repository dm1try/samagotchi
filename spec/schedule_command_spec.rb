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
  before do
    @clock = Time.now
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("schedule.auto_tick").and_return(false)
    allow(Samagotchi::Config).to receive(:get).with("schedule.tick_interval_minutes").and_return(5)
  end

  let(:schedules) { Samagotchi::Schedules.new(state_dir: @dir, clock: -> { @clock }) }
  let(:every) { Samagotchi::Schedules.recurrence(every: "1m") }
  let(:hourly) { Samagotchi::Schedules.recurrence(every: "1h") }

  def tick_warning
    "Warning: no schedule tick in the last 10 minutes; set schedule.auto_tick: true or " \
      "run `chi schedule tick` from cron."
  end

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
  # Removes every schedule from the file between #change's lookup and its
  # lock: another terminal's cancel landing in between.
  def vanish_before_lock(schedules)
    allow(schedules).to receive(:write_under_lock).and_wrap_original do |original, &block|
      data = JSON.parse(File.read(schedules.path))
      data["schedules"] = []
      File.write(schedules.path, JSON.generate(data))
      original.call(&block)
    end
  end

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
                            "next #{Time.iso8601(entry.next_due).localtime.strftime("%Y-%m-%d %H:%M")}\n" \
                            "#{tick_warning}\n")
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
      expect(printed).to eq("no schedules\n#{tick_warning}\n")

      entry = schedules.add(target: id, prompt: "Audit", recurrence: hourly)
      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id}  \"Audit\"  chain  every 1h  " \
                            "#{Time.iso8601(entry.next_due).localtime.strftime("%Y-%m-%d %H:%M")}  #{id[0, 8]}\n" \
                            "#{tick_warning}\n")

      schedules.disable(entry.id)
      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to eq("no schedules\n#{tick_warning}\n")

      status, printed, error = run("list", "--all")
      expect(status).to eq(0), error
      expect(printed).to include(" disabled\n")
      expect(printed).not_to include("disabled after")
    end

    it "says when skips disabled an entry" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every, max_skips: 1)
      Samagotchi::SessionInbox.write_input(Samagotchi::Session.session_dir(id, state_dir: @dir), prompt: "busy")
      schedules.tick(now: @clock + 120)

      status, printed, error = run("list", "--all")
      expect(status).to eq(0), error
      expect(printed).to include("#{entry.id} ", "disabled after 1 skip")
    end

    it "says when failures disabled an entry" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every, max_failures: 1)
      FileUtils.rm_f(Samagotchi::Session.session_file(id, state_dir: @dir))
      FileUtils.rm_rf(Samagotchi::Session.session_dir(id, state_dir: @dir))
      schedules.tick(now: @clock + 120)

      status, printed, error = run("list", "--all")
      expect(status).to eq(0), error
      expect(printed).to include("#{entry.id} ", "disabled after 1 failure")
    end

    it "names each row: its title, or the start of its prompt in quotes" do
      id = session
      titled = schedules.add(target: id, title: "coordinator-heartbeat", prompt: "Audit the open PRs", recurrence: hourly)
      cut = schedules.add(target: id, prompt: "Check the pod logs, then write a recap", recurrence: hourly)
      brief = schedules.add(target: id, prompt: "Review the weekly\nmetrics", recurrence: hourly)

      status, printed, error = run("list")
      expect(status).to eq(0), error
      rows = printed.lines.map(&:chomp)

      expect(rows.find { |line| line.start_with?(titled.id) }).to include("  coordinator-heartbeat  ")
      expect(rows.find { |line| line.start_with?(cut.id) }).to include("\"Check the pod logs, then write…\"")
      expect(rows.find { |line| line.start_with?(brief.id) }).to include("\"Review the weekly metrics\"")
    end

    it "pads the name column to the widest name so the columns after it line up" do
      id = session
      short = schedules.add(target: id, title: "Audit", prompt: "Audit", recurrence: hourly)
      wide = schedules.add(target: id, prompt: "Check the pod logs, then write a recap", recurrence: hourly)
      name_width = "\"Check the pod logs, then write…\"".length

      status, printed, error = run("list")
      expect(status).to eq(0), error
      due = Time.iso8601(short.next_due).localtime.strftime("%Y-%m-%d %H:%M")
      rows = printed.lines.map(&:chomp)

      expect(rows.find { |line| line.start_with?(short.id) })
        .to eq("#{short.id}  #{"Audit".ljust(name_width)}  chain  every 1h  #{due}  #{id[0, 8]}")
      expect(rows.find { |line| line.start_with?(wide.id) })
        .to eq("#{wide.id}  \"Check the pod logs, then write…\"  chain  every 1h  #{due}  #{id[0, 8]}")
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
      expect(rows.first["title"]).to eq("Audit")
      expect(error).to eq("#{tick_warning}\n")
    end

    it "--format json carries the title, and never the quoted prompt stand-in" do
      id = session
      titled = schedules.add(target: id, title: "Audit", prompt: "Audit the open PRs", recurrence: every)
      untitled = schedules.add(target: id, prompt: "Check the pod logs, then write a recap", recurrence: every)

      status, printed, error = run("list", "--format", "json")
      expect(status).to eq(0), error
      rows = JSON.parse(printed)

      expect(rows.find { |row| row["id"] == titled.id }["title"]).to eq("Audit")
      expect(rows.find { |row| row["id"] == untitled.id }["title"]).to be_nil
      expect(rows.find { |row| row["id"] == untitled.id }["prompt"]).to eq("Check the pod logs, then write a recap")
      expect(rows.flat_map(&:values)).not_to include("\"Check the pod logs, then write…\"")
    end
  end

  it "refuses a --format other than text or json for list and tick, exit 2 and nothing ticked" do
    expect(schedules).not_to receive(:tick)
    %w[list tick].each do |sub|
      status, printed, error = run(sub, "--format", "xml")
      expect([status, printed]).to eq([2, ""])
      expect(error).to start_with(%(chi schedule #{sub}: unknown format "xml": use --format text|json\n))
    end
    expect(run("list", "--format", "text").first).to eq(0)
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

    it "prints the run history newest first, one line each in local time; list's JSON carries it" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every)
      status, printed, = run("show", entry.id)
      expect(status).to eq(0)
      expect(printed).to end_with("  history: -\n")

      first = Time.utc(2026, 11, 24, 9, 0)
      data = JSON.parse(File.read(schedules.path))
      data["schedules"].first["history"] = [
        { "at" => first.iso8601, "status" => "skipped", "detail" => "a turn is running in it", "session_id" => id },
        { "at" => (first + 300).iso8601, "status" => "fired", "detail" => "turn completed", "session_id" => id },
        { "at" => (first + 600).iso8601, "status" => "disabled", "detail" => nil, "session_id" => nil }
      ]
      File.write(schedules.path, JSON.generate(data))

      status, printed, error = run("show", entry.id)
      expect(status).to eq(0), error
      local = ->(time) { time.localtime.strftime("%Y-%m-%d %H:%M") }
      expect(printed).to end_with(
        "  history (newest first):\n    " \
        "#{local.call(first + 600)}  disabled\n    " \
        "#{local.call(first + 300)}  fired  turn completed  #{id[0, 8]}\n    " \
        "#{local.call(first)}  skipped  a turn is running in it  #{id[0, 8]}\n"
      )

      _, printed, = run("list", "--format", "json")
      expect(JSON.parse(printed).first["history"].map { |row| row["status"] }).to eq(%w[skipped fired disabled])
    end

    it "shows the last turn failure reason in list and show" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every)
      data = JSON.parse(File.read(schedules.path))
      data["schedules"].first["last_result"] = "turn failed: model unavailable"
      File.write(schedules.path, JSON.generate(data))

      status, printed, error = run("list")
      expect(status).to eq(0), error
      expect(printed).to include("last: turn failed: model unavailable")

      status, printed, error = run("show", entry.id)
      expect(status).to eq(0), error
      expect(printed).to include("last result: turn failed: model unavailable")
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
      expect([outcome["id"], outcome["status"]]).to eq([entry.id, "pending"])
      expect(outcome["detail"]).to match(/\Anew link \h{8}\z/)

      stored = schedules.lookup(entry.id)
      expect(stored.head[0, 8]).to eq(outcome["detail"].split.last)
      expect(Time.iso8601(stored.next_due)).to be > @clock
    end

    it "adds a \"disabled\" key in json to the outcome that disabled its schedule, and nothing else" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every, max_failures: 2)
      FileUtils.rm_f(Samagotchi::Session.session_file(id, state_dir: @dir))
      FileUtils.rm_rf(Samagotchi::Session.session_dir(id, state_dir: @dir))
      due

      status, printed, error = run("tick", "--format", "json")
      expect(status).to eq(0), error
      expect(JSON.parse(printed)["outcomes"].first.keys).to eq(%w[id status detail])
      due
      status, printed, error = run("tick", "--format", "json")
      expect(status).to eq(0), error
      expect(JSON.parse(printed)["outcomes"]).to eq([{ "id" => entry.id, "status" => "failed",
                                                       "detail" => "the chain is gone", "disabled" => true }])
    end

    it "prints (disabled) on the tick line that disabled its schedule" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every, max_failures: 1)
      FileUtils.rm_rf(Samagotchi::Session.session_dir(id, state_dir: @dir))
      FileUtils.rm_f(Samagotchi::Session.session_file(id, state_dir: @dir))
      due

      status, printed, error = run("tick")
      expect(status).to eq(0), error
      expect(printed).to eq("#{entry.id}  failed  the chain is gone (disabled)\n")
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

    it "reports a corrupt schedule file on one line and leaves it as is" do
      File.write(schedules.path, "{broken")

      status, printed, error = run("tick")

      expect(status).to eq(1)
      expect(printed).to be_empty
      expect(error).to include(schedules.path, "left as is")
      expect(error.lines.size).to eq(1)
      expect(File.read(schedules.path)).to eq("{broken")
    end
  end

  describe "edit" do
    it "changes only the fields given, keeps the budgets and counters, and prints the updated row" do
      id = session
      entry = schedules.add(target: id, prompt: "Audit", title: "Audit", recurrence: hourly, max_skips: 7, max_failures: 2,
                            keep_links: 3)
      schedules.send(:write_under_lock) { |file| file.entries.map! { |stored| stored.with(skips: 2, failures: 1) } }

      status, printed, error = run("edit", entry.id, "--title", "Morning audit", "-m", "Audit the queue")
      expect(status).to eq(0), error
      edited = schedules.lookup(entry.id)
      expect(edited).to have_attributes(title: "Morning audit", prompt: "Audit the queue", recurrence: hourly,
                                        next_due: entry.next_due, max_skips: 7, max_failures: 2, keep_links: 3,
                                        skips: 2, failures: 1, enabled: true, anchor: id, mode: "chain")
      expect(printed).to start_with("#{entry.id}  Morning audit  chain  every 1h")
      expect(edited.history.last).to include(status: "edited", detail: "title, prompt")
    end

    it "sets catch-up and each budget" do
      entry = schedules.add(target: session, prompt: "Audit", recurrence: hourly)

      status, _, error = run("edit", entry.id, "--catch-up", "none", "--keep-links", "0", "--max-failures", "9",
                             "--max-skips", "30")
      expect(status).to eq(0), error
      expect(schedules.lookup(entry.id)).to have_attributes(catch_up: "none", keep_links: 0, max_failures: 9, max_skips: 30)
      expect(schedules.lookup(entry.id).history.last[:detail]).to eq("catch_up, keep_links, max_failures, max_skips")

      status, _, error = run("edit", entry.id, "--catch-up", "later")
      expect(status).to eq(2)
      expect(error).to include("catch_up must be one of once, none")
      status, _, error = run("edit", entry.id, "--max-skips", "lots")
      expect(status).to eq(2)
      expect(error).to include("max_skips must be a number")
    end

    it "recomputes next_due from a new recurrence and clears due_was" do
      entry = schedules.add(target: session, prompt: "Audit", recurrence: every)
      schedules.send(:write_under_lock) { |file| file.entries.map! { |stored| stored.with(due_was: stored.next_due) } }

      status, _, error = run("edit", entry.id, "--weekday", "3", "--time", "07:30")
      expect(status).to eq(0), error
      edited = schedules.lookup(entry.id)
      expect(edited.recurrence).to eq(kind: "weekday", weekday: 3, time: "07:30")
      due = Time.iso8601(edited.next_due).localtime
      expect([due.wday, due.hour, due.min]).to eq([3, 7, 30])
      expect(due).to be > @clock
      expect(edited.due_was).to be_nil
    end

    it "refuses the session and mode flags, --time alone, nothing to change and an unknown id" do
      entry = schedules.add(target: session, prompt: "Audit", recurrence: hourly)
      [["--session", "abc"], ["--continues", "abc"], ["--mode", "same"]].each do |flag|
        status, _, error = run("edit", entry.id, *flag)
        expect(status).to eq(2)
        expect(error).to include("edit can't change the session or mode: cancel it and add a new one")
      end

      status, _, error = run("edit", entry.id, "--time", "10:00")
      expect(status).to eq(2)
      expect(error).to include("a schedule needs one of every, weekday or date")

      status, _, error = run("edit", entry.id)
      expect(status).to eq(2)
      expect(error.lines.first).to start_with("chi schedule edit: nothing to change")

      status, _, error = run("edit")
      expect(status).to eq(2)
      expect(error.lines.first).to eq("chi schedule edit: edit needs a schedule id\n")

      status, _, error = run("edit", "gone", "--title", "X")
      expect([status, error]).to eq([1, "no schedule gone\n"])
      expect(schedules.lookup(entry.id).history).to eq([])
    end

    it "refuses another entry's title in the chain but takes its own" do
      id = session
      first = schedules.add(target: id, prompt: "Audit", title: "Audit", recurrence: hourly)
      second = schedules.add(target: id, prompt: "Weekly", title: "Weekly", recurrence: every)

      status, _, error = run("edit", second.id, "--title", "audit")
      expect(status).to eq(2)
      expect(error).to include("#{first.id} already schedules this")

      status, _, error = run("edit", first.id, "--title", "Audit", "-m", "Audit again")
      expect(status).to eq(0), error
    end

    it "takes a budget edit of a disabled entry whose twin (same title) is on" do
      id = session
      first = schedules.add(target: id, prompt: "One", title: "Audit", recurrence: hourly)
      schedules.disable(first.id)
      schedules.add(target: id, prompt: "Two", title: "Audit", recurrence: hourly)

      status, _, error = run("edit", first.id, "--max-skips", "5")
      expect(status).to eq(0), error
      expect(schedules.lookup(first.id).max_skips).to eq(5)
    end

    it "refuses a recurrence edit while a firing is in flight, and takes a prompt edit for the next firing" do
      entry = schedules.add(target: session, prompt: "Audit", recurrence: hourly)
      schedules.send(:write_under_lock) do |file|
        file.entries.map! { |stored| stored.with(firing_since: @clock.utc.iso8601, pending_turn_id: "turn") }
      end

      status, _, error = run("edit", entry.id, "--every", "2h")
      expect(status).to eq(2)
      expect(error).to include("a run is in progress; edit the time after it settles")
      expect(schedules.lookup(entry.id).recurrence).to eq(hourly)

      status, _, error = run("edit", entry.id, "-m", "Audit later")
      expect(status).to eq(0), error
      expect(schedules.lookup(entry.id)).to have_attributes(prompt: "Audit later", pending_turn_id: "turn")
    end

    it "leaves a spent date one-off disabled" do
      entry = schedules.add(target: session, prompt: "Once", recurrence: Samagotchi::Schedules.recurrence(date: "2026-11-20T09:00"))
      schedules.send(:write_under_lock) { |file| file.entries.map! { |stored| stored.with(enabled: false, next_due: nil) } }

      status, printed, error = run("edit", entry.id, "--date", "2027-01-05T09:00")
      expect(status).to eq(0), error
      expect(schedules.lookup(entry.id)).to have_attributes(enabled: false)
      expect(printed).to include("disabled")
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
      expect(printed).to eq("#{entry.id[0, 8]}: pending · new link #{printed.split.last[0, 8]}\n")
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

    it "says no schedule, exit 1, when the entry is gone by the time the lock is held" do
      id = session
      %w[cancel enable disable].each do |sub|
        entry = schedules.add(target: id, prompt: "Audit #{sub}", recurrence: every)
        vanish_before_lock(schedules)

        status, printed, error = run(sub, entry.id)
        expect([status, printed, error]).to eq([1, "", "no schedule #{entry.id}\n"])
        RSpec::Mocks.space.proxy_for(schedules).reset
      end
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
      expect(printed).to start_with("Usage: chi schedule <add|edit|list|show|tick|run-now|enable|disable|cancel> [flags]\n")

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
