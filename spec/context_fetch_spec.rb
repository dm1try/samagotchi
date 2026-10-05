# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/context_fetch"

RSpec.describe Samagotchi::ContextFetch do
  let(:tmpdir) { Dir.mktmpdir("context-fetch") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions") }
  let(:work) { File.join(tmpdir, "work").tap { |d| FileUtils.mkdir_p(d) } }
  let(:loc) { Samagotchi::ContextSources.session_location("11111111-2222-3333-4444-555555555555", state_dir: state_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  def source(cmd, name: "src")
    loc.add(Samagotchi::ContextSources::Source.new(name: name, cmd: cmd, every_seconds: nil, why: nil, hint: nil,
                                                   scope: "session", added_by: "cli", created_at: nil))
    Samagotchi::ContextSources::Attached.new(source: loc.source(name), location: loc, shadowed: false)
  end

  def fetch(attached, **opts) = described_class.fetch(attached, cwd: work, **opts)

  it "keeps a command's stdout as the text, run in cwd, and says when it's the same again" do
    File.write(File.join(work, "data.txt"), "from the folder\n")
    attached = source("cat data.txt")

    first = fetch(attached)
    expect(first).to have_attributes(status: :new, error: nil)
    expect(first.snapshot).to have_attributes(text: "from the folder\n", serial: 1, summary: "1 line of text")
    expect(fetch(attached).status).to eq(:same)
  end

  it "reads the JSON contract" do
    attached = source(%(printf '{"text":"PR","summary":"2 new comments","wake":true}'))

    expect(fetch(attached).snapshot).to have_attributes(text: "PR", summary: "2 new comments", wake: true)
  end

  it "passes the source's name and, from the second run, the previous snapshot's path" do
    attached = source(%(echo "$SAMAGOTCHI_CONTEXT_NAME ${SAMAGOTCHI_CONTEXT_PREVIOUS:-none} $(date +%s%N)"))

    expect(fetch(attached).snapshot.text).to start_with("src none ")
    expect(fetch(attached).snapshot.text).to start_with("src #{loc.snapshot_path("src")} ")
  end

  it "records a failure with the exit status and stderr's last line, keeping the last good text" do
    marker = File.join(work, "fail")
    attached = source(%(if [ -e fail ]; then echo first >&2; echo "gh: not logged in" >&2; exit 4; fi; echo good))
    fetch(attached)
    FileUtils.touch(marker)

    outcome = fetch(attached)

    expect(outcome).to have_attributes(status: :error, error: "exit 4: gh: not logged in")
    expect(outcome.snapshot).to have_attributes(text: "good\n", error: "exit 4: gh: not logged in")
  end

  it "fails on empty output" do
    expect(fetch(source("true")).error).to eq("the output is empty")
  end

  it "kills the command's whole process group at the timeout, leaving no orphan" do
    pid_file = File.join(work, "child.pid")
    attached = source("sleep 30 & echo $! > child.pid; wait")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = fetch(attached, timeout: 0.5)

    expect(outcome.error).to eq("timed out after 1 s")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    child = File.read(pid_file).to_i
    expect(wait_until { !alive?(child) }).to be(true)
  end

  # Smoke 2026-10-06: a worker's idle exit cut a project source's fetch,
  # and every other session of the project got "couldn't refresh".
  it "kills it when the caller cancels (the worker stops), recording nothing: a stop isn't the source's failure" do
    attached = source("if [ -e slow ]; then sleep 30; fi; echo good")
    fetch(attached)
    FileUtils.touch(File.join(work, "slow"))

    outcome = fetch(attached, cancelled: -> { true })

    expect(outcome.status).to eq(:cancelled)
    expect(loc.snapshot("src")).to have_attributes(text: "good\n", error: nil)
  end

  it "refuses more than 1 MiB of output" do
    outcome = fetch(source("yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -c 2000000"))
    expect(outcome.error).to eq("it printed more than 1 MiB")
  end

  it "says when its folder is gone" do
    outcome = described_class.fetch(source("echo hi"), cwd: File.join(tmpdir, "gone"))
    expect(outcome.error).to eq("its folder #{File.join(tmpdir, "gone")} is gone")
  end

  it "skips a source someone else holds the lock of, and one tried within fresh_within" do
    attached = source("echo hi")
    File.open(loc.lock_path("src"), File::RDWR | File::CREAT) do |lock|
      lock.flock(File::LOCK_EX)
      expect(fetch(attached).status).to eq(:busy)
    end

    fetch(attached)
    expect(fetch(attached, fresh_within: 60).status).to eq(:fresh)
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
