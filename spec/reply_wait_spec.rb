# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/reply_wait"
require "samagotchi/session_manager"

# A session's next reply: an output/ file past the caller's cursor, or the
# reason none will come.
RSpec.describe Samagotchi::ReplyWait do
  let(:tmpdir) { Dir.mktmpdir("reply-wait") }
  let(:session) { make(status: "running") }
  let(:threads) { [] }

  after do
    threads.each(&:join)
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(status:)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.status = status
      s.save(state_dir: tmpdir)
    end
  end

  def set(status: nil, pending_question: :keep, last_prompt: nil)
    s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
    s.status = status if status
    s.pending_question = pending_question unless pending_question == :keep
    s.last_prompt = last_prompt if last_prompt
    s.save(state_dir: tmpdir)
  end

  # A live worker holds the session (the owner lock), so its question waits for an answer.
  def own_by_worker
    lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: "worker")
    locks << lock
  end

  let(:locks) { [] }

  def write_reply(text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  def later(delay = 0.1, &block)
    threads << Thread.new do
      sleep(delay)
      block.call
    end
  end

  def wait(cursor: nil, timeout: 5, **opts)
    described_class.call(session.id, state_dir: tmpdir, cursor: cursor, timeout: timeout, poll_interval: 0.02, **opts)
  end

  it "returns a reply file past the cursor, with its name as the next cursor" do
    write_reply("old")
    cursor = described_class.newest_reply(session.id, state_dir: tmpdir)
    later { write_reply("new") }

    result = wait(cursor: cursor)
    expect(result.status).to eq(:done)
    expect(result.text).to eq("new")
    expect(result.file).to be > cursor
  end

  it "takes any reply with no cursor" do
    write_reply("there already")
    expect(wait.text).to eq("there already")
  end

  it "ends without a reply when the session ran and went idle" do
    later { set(status: "idle") }
    expect(wait.status).to eq(:no_reply)
  end

  it "keeps waiting on a session it never saw running (a message not picked up yet)" do
    set(status: "idle")
    later do
      set(status: "running")
      sleep(0.1)
      write_reply("late")
      set(status: "idle")
    end
    expect(wait.text).to eq("late")
  end

  it "returns a pending question" do
    own_by_worker
    set(pending_question: { id: "q1", kind: "approval", question: "Run rm?" })
    result = wait
    expect(result.status).to eq(:waiting_for_answer)
    expect(result.question).to include(id: "q1", kind: "approval")
  end

  it "does not report a question a dead worker left: it waits for no one, and the worker is gone" do
    set(pending_question: { id: "q1", question: "Which?" })

    expect(wait(timeout: 0.2).status).to eq(:timeout)
    expect(wait(owner_grace: 0.1).status).to eq(:worker_gone)
  end

  it "does not report a question a chi REPL holds" do
    locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: "tui")
    set(pending_question: { id: "q1", question: "Which?" })

    expect(wait(timeout: 0.2).status).to eq(:timeout)
  end

  it "returns a failed or stopped worker" do
    set(status: "error", last_prompt: "boom ")
    expect(wait).to have_attributes(status: :error, text: "boom")

    set(status: "stopped")
    expect(wait.status).to eq(:stopped)
  end

  it "stops when cancelled" do
    flag = [false]
    later { flag[0] = true }
    expect(wait(cancelled: -> { flag[0] }).status).to eq(:canceled)
  end

  it "times out, and waits with no limit on nil" do
    expect(wait(timeout: 0).status).to eq(:timeout)

    later(0.3) { write_reply("eventually") }
    expect(wait(timeout: nil).text).to eq("eventually")
  end

  it "calls interject once a poll, and doesn't count its time against the timeout" do
    # The first interject outlasts the timeout; the reply comes from the
    # second, so the wait has to poll again after it (no thread timing).
    calls = 0
    interject = lambda do
      calls += 1
      sleep(0.5) if calls == 1
      write_reply("after the interject") if calls == 2
    end
    result = wait(timeout: 0.3, interject: interject)
    expect(result.text).to eq("after the interject")
    expect(calls).to eq(2)
  end

  it "stops right after an interject during which the wait was cancelled" do
    flag = [false]
    expect(wait(interject: -> { flag[0] = true }, cancelled: -> { flag[0] }).status).to eq(:canceled)
  end

  describe "with a baseline" do
    let(:session) { make(status: "idle") }

    it "ends when the messages grew and it is idle, though never seen running (a turn that failed within one poll)" do
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.messages << { role: "user", content: "[turn failed]" }
      s.save(state_dir: tmpdir)

      expect(wait(baseline: { messages: 0, question_id: nil }).status).to eq(:no_reply)
    end

    it "says a turn ran out of iterations when its last_turn is marked exhausted (nobody asked to continue)" do
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "completed", "ended_at" => "2026-10-03T10:00:00.000+00:00", "exhausted" => true, "limit" => 3 }
      s.save(state_dir: tmpdir)

      result = wait(baseline: baseline)
      expect(result.to_h).to include(status: :no_reply, outcome: "exhausted", limit: 3)
    end

    it "ignores the question pending at the baseline, not a new one" do
      own_by_worker
      set(pending_question: { id: "old", question: "Old?" })
      later { set(pending_question: { id: "new", question: "New?" }) }

      expect(wait(baseline: { messages: 0, question_id: "old" }).question).to include(id: "new")
    end
  end

  it "reports a worker gone past the grace, not one that comes back" do
    owner = [nil]
    allow(Samagotchi::SessionManager).to receive(:session_owner) { owner[0] }
    expect(wait(owner_grace: 0.1).status).to eq(:worker_gone)

    # Gone for the first two looks only, far inside the grace however slow
    # the runner: no race between a thread's sleep and the wait's clock.
    looks = 0
    allow(Samagotchi::SessionManager).to receive(:session_owner) do
      looks += 1
      write_reply("came back") if looks == 5
      looks > 2 ? Samagotchi::OwnerLock::Owner.new(pid: 1) : nil
    end
    expect(wait(owner_grace: 1).text).to eq("came back")
    expect(looks).to be >= 5
  end

  it "raises for a missing session" do
    expect { described_class.call("nope", state_dir: tmpdir, cursor: nil) }.to raise_error(ArgumentError)
  end
end
