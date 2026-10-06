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

  # Review 2026-10-06: Ctrl-C in chi context refresh (or a worker thread
  # killed at stop) left the command's group running: pgroup: true keeps
  # the terminal's SIGINT from it.
  it "stops the command's whole group and reaps it when an Interrupt cuts the fetch" do
    sh_file = File.join(work, "sh.pid")
    child_file = File.join(work, "child.pid")
    attached = source("echo $$ > sh.pid; sleep 30 & echo $! > child.pid; wait")
    interrupt = -> { File.size?(child_file) ? raise(Interrupt) : false }

    expect { fetch(attached, cancelled: interrupt) }.to raise_error(Interrupt)

    # kill(0) still finds a zombie: sh gone means it was reaped too.
    expect(alive?(File.read(sh_file).to_i)).to be(false)
    expect(wait_until { !alive?(File.read(child_file).to_i) }).to be(true)
  end

  it "stops the group when the fetching thread is killed (a poller left behind at exit)" do
    sh_file = File.join(work, "sh.pid")
    child_file = File.join(work, "child.pid")
    attached = source("echo $$ > sh.pid; sleep 30 & echo $! > child.pid; wait")
    thread = Thread.new { fetch(attached) }
    expect(wait_until { File.size?(child_file) }).to be_truthy

    thread.kill.join(5)

    expect(alive?(File.read(sh_file).to_i)).to be(false)
    expect(wait_until { !alive?(File.read(child_file).to_i) }).to be(true)
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

  it "KILLs a group that ignores TERM once the grace is over" do
    stub_const("#{described_class}::KILL_GRACE_SECONDS", 0.2)
    pid_file = File.join(work, "child.pid")
    attached = source("trap '' TERM; sleep 31.77 & echo $! > child.pid; wait")

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    outcome = fetch(attached, timeout: 0.3)

    expect(outcome.error).to eq("timed out after 0 s")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    expect(wait_until { !alive?(File.read(pid_file).to_i) }).to be(true)
  end

  it "keeps only stderr's last 4 KiB" do
    run = described_class.run_command("head -c 9000 /dev/zero | tr '\\0' a >&2; echo >&2; echo END >&2; exit 3",
                                      cwd: work, env: {}, timeout: 5, cancelled: -> { false })

    expect(run.stderr.bytesize).to be <= described_class::STDERR_TAIL_BYTES
    expect(run.stderr).to end_with("a\nEND\n")
    expect(run.error).to eq("exit 3: END")
  end

  it "refuses more than 1 MiB of output" do
    outcome = fetch(source("yes xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx | head -c 2000000"))
    expect(outcome.error).to eq("it printed more than 1 MiB")
  end

  # Review 2026-10-06: a command just over the cap that exited before the
  # next 50 ms tick was saved as a good, cut snapshot. A blocking wait2
  # makes "exited before the cap was seen" certain.
  it "refuses output just over 1 MiB from a command that exits at once" do
    allow(Process).to(receive(:wait2).and_wrap_original { |original, pid, *_flags| original.call(pid) })
    attached = source("head -c #{Samagotchi::ContextSources::TEXT_MAX_BYTES + 10_000} /dev/zero | tr '\\0' x")

    outcome = fetch(attached)

    expect(outcome).to have_attributes(status: :error, error: "it printed more than 1 MiB")
    expect(loc.snapshot("src").text).to be_nil
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

  # R1 (part 1 review): a source removed, or removed and added again with
  # another command, while its fetch runs gets nothing written back, and
  # the lock outlives the removal, so a fetch of the new one waits.
  describe "a source removed while its fetch runs" do
    let(:gate) { File.join(tmpdir, "gate") }

    def removed_mid_fetch(readd: nil)
      attached = source("while [ ! -e #{gate} ]; do sleep 0.05; done; echo old text")
      outcome = nil
      thread = Thread.new { outcome = fetch(attached) }
      expect(wait_until { File.exist?(loc.lock_path("src")) }).to be(true)
      loc.remove("src")
      source(readd) if readd
      yield if block_given?
      FileUtils.touch(gate)
      thread.join(10)
      outcome
    end

    it "writes nothing back" do
      outcome = removed_mid_fetch

      expect(outcome.status).to eq(:gone)
      expect(File.exist?(loc.snapshot_path("src"))).to be(false)
    end

    it "leaves the new source of that name alone, whose fetch waits for the lock" do
      outcome = removed_mid_fetch(readd: "echo new text") do
        expect(fetch(Samagotchi::ContextSources::Attached.new(source: loc.source("src"), location: loc, shadowed: false)).status)
          .to eq(:busy)
      end

      expect(outcome.status).to eq(:gone)
      expect(loc.snapshot("src").text).to be_nil
      expect(fetch(Samagotchi::ContextSources::Attached.new(source: loc.source("src"), location: loc, shadowed: false)).snapshot.text)
        .to eq("new text\n")
    end
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end
end
