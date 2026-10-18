# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/reply_wait"
require "samagotchi/session_manager"

# A session's next reply: an output/ file past the caller's cursor, or the
# reason none will come.
RSpec.describe Samagotchi::ReplyWait do
  # A reply's session left running in the fixture never gets the worker's
  # save that ReplyWait.settled waits up to SETTLE_SECONDS (1 s) for: 0.1 s
  # here, but in an example about that wait (:real_settle).
  before { |example| stub_const("Samagotchi::ReplyWait::SETTLE_SECONDS", 0.1) unless example.metadata[:real_settle] }

  let(:tmpdir) { Dir.mktmpdir("reply-wait") }
  let(:session) { make(status: "running") }
  let(:threads) { [] }
  let(:locks) { [] }

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

  def write_reply(text)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), text)
    sleep(0.002)
  end

  # Runs the block on a thread once the wait has looked (+delay+ nil), or
  # after +delay+ seconds when the time itself matters.
  def later(delay = nil, &)
    threads << Thread.new do
      delay ? sleep(delay) : looked(1)
      yield
    end
  end

  # The looks the example's waits made: each poll calls its interject.
  def polls = (@polls ||= [0])

  # Blocks until the waits made +count+ more looks: 2 is a whole look at
  # what the caller set just before.
  def looked(count)
    start = polls[0]
    wait_until { polls[0] >= start + count }
  end

  def wait(cursor: nil, timeout: 5, interject: nil, **opts)
    counting = lambda do
      interject&.call
      polls[0] += 1
    end
    described_class.call(session.id, state_dir: tmpdir, cursor: cursor, timeout: timeout, poll_interval: 0.02, interject: counting, **opts)
  end

  describe "the session it hands back (a caller's next baseline)" do
    it "is the session the deciding look loaded" do
      set(status: "error", last_prompt: "boom")
      expect(wait.session.status).to eq("error")
    end

    it "for a reply found before the worker's save, is the session after that save", :real_settle do
      write_reply("hi") # the worker writes the reply, then saves idle with the turn's last_turn
      later(0.1) do
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "idle"
        s.last_turn = { "outcome" => "completed", "ended_at" => "2026-10-05T10:00:00.000Z" }
        s.save(state_dir: tmpdir)
      end

      result = wait
      expect(result.status).to eq(:done)
      expect(result.session.last_turn.ended_at).to eq("2026-10-05T10:00:00.000Z")
    end
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
      looked(2)
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
    expect(result.question).to have_attributes(id: "q1", kind: "approval")
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

    it "waits on past a note that joined between turns (a new worker's context note before the message's turn)" do
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.messages << { role: "system", content: "[CONTEXT NOTE from context notes]", kind: "note" }
      s.save(state_dir: tmpdir)
      later(0.2) { write_reply("the answer") }

      expect(wait(baseline: baseline).to_h).to include(status: :done, text: "the answer")
    end

    it "says a turn ran out of iterations when its last_turn is marked exhausted (nobody asked to continue)" do
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "completed", "ended_at" => "2026-10-03T10:00:00.000+00:00", "exhausted" => true, "limit" => 3 }
      s.save(state_dir: tmpdir)

      result = wait(baseline: baseline)
      expect(result.to_h).to include(status: :no_reply, outcome: "exhausted", limit: 3)
    end

    it "says why the turn stopped, from its last_turn: a failure's kind, a cancel's reason and who" do
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "failed", "ended_at" => "2026-10-04T10:00:00.000+00:00", "error_kind" => "credits",
                      "retryable" => false }
      s.save(state_dir: tmpdir)
      expect(wait(baseline: baseline).to_h).to include(status: :no_reply, outcome: "failed", error_kind: "credits",
                                                       retryable: false, stopped_by: nil, cancel_reason: nil)

      baseline = described_class.baseline_of(s)
      s.last_turn = { "outcome" => "canceled", "ended_at" => "2026-10-04T10:01:00.000+00:00", "cancel_reason" => "hook",
                      "stopped_by" => "loop-guard" }
      s.save(state_dir: tmpdir)
      expect(wait(baseline: baseline).to_h).to include(outcome: "canceled", cancel_reason: "hook", stopped_by: "loop-guard",
                                                       error_kind: nil)
    end

    it "reads a failed turn whose work stayed: its kept_steps, and the summary from its note" do
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.messages << Samagotchi::TurnNote.failed("out of credits on host or: x", steps: 2)
      s.last_turn = { "outcome" => "failed", "ended_at" => "2026-10-04T10:00:00.000+00:00", "error_kind" => "credits",
                      "kept_steps" => 2 }
      s.save(state_dir: tmpdir)

      expect(wait(baseline: baseline).to_h).to include(status: :no_reply, outcome: "failed", kept_steps: 2,
                                                       text: "out of credits on host or: x")
    end

    # A worker died in a turn (the file says running, with its mark); the
    # message's own worker settles that turn (idle, same last_turn), then
    # runs the message's turn: only that turn's end ends the wait.
    it "waits on past a dead worker's turn going idle as it is settled, until a turn ends since the baseline" do
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "completed", "ended_at" => "2026-10-04T10:00:00.000+00:00" }
      s.interrupted_turn = { "id" => "t0", "iteration" => 3 }
      s.status = "running"
      s.save(state_dir: tmpdir)
      baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      later(0.1) { set(status: "idle") }
      later(0.3) { set(status: "running") }

      expect(wait(baseline: baseline, timeout: 0.6).status).to eq(:timeout)

      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.status = "idle"
      s.last_turn = { "outcome" => "canceled", "ended_at" => "2026-10-04T10:05:00.000+00:00", "cancel_reason" => "user" }
      s.save(state_dir: tmpdir)
      expect(wait(baseline: baseline).to_h).to include(status: :no_reply, outcome: "canceled", cancel_reason: "user")
    end

    it "ignores the question pending at the baseline, not a new one" do
      own_by_worker
      set(pending_question: { id: "old", question: "Old?" })
      later { set(pending_question: { id: "new", question: "New?" }) }

      expect(wait(baseline: { messages: 0, question_id: "old" }).question).to have_attributes(id: "new")
    end
  end

  # The turn that ended before the baseline (chi send --wait with no message,
  # on a session that went idle in the gap between waits): its end is the
  # answer, not a wait that times out "running".
  describe "with ended_before: (a settled session's finished turn)" do
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    # The worker's order: the turn ends (last_turn gets its ended_at), then
    # its reply is written, at least as new.
    def finish(outcome:, seconds_ago: 2, **facts)
      Samagotchi::Session.load(session.id, state_dir: tmpdir).tap do |s|
        s.status = "idle"
        s.last_turn = Samagotchi::LastTurn.new(outcome: outcome,
                                               ended_at: (Time.now - seconds_ago).iso8601(3), **facts)
        s.save(state_dir: tmpdir)
      end
    end

    def baseline
      described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
    end

    it "returns the finished turn's reply, at the cursor, not past it" do
      finish(outcome: "completed")
      write_reply("the finished answer")

      result = wait(cursor: described_class.newest_reply(session.id, state_dir: tmpdir),
                    baseline: baseline, ended_before: true)
      expect(result.status).to eq(:done)
      expect(result.text).to eq("the finished answer")
    end

    it "returns the finished turn's no-reply outcome when its newest reply is an earlier turn's" do
      # The earlier turn's reply is older than the finished turn's end
      # (it was written at the earlier turn's, so it predates this one).
      write_reply("an earlier answer")
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.status = "idle"
      s.last_turn = Samagotchi::LastTurn.new(outcome: "failed", ended_at: Time.now.iso8601(3),
                                             error_kind: "server")
      s.save(state_dir: tmpdir)

      result = wait(cursor: described_class.newest_reply(session.id, state_dir: tmpdir),
                    baseline: baseline, ended_before: true)
      expect(result.to_h).to include(status: :no_reply, outcome: "failed", error_kind: "server")
    end

    it "returns the finished turn's no-reply outcome with no reply at all" do
      finish(outcome: "canceled", cancel_reason: "user")

      result = wait(baseline: baseline, ended_before: true)
      expect(result.to_h).to include(status: :no_reply, outcome: "canceled", cancel_reason: "user")
    end

    it "with no last_turn at the baseline (a session that never ran), still reports a turn that ends since" do
      set(status: "idle")
      base = baseline
      later do
        write_reply("the first answer")
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3))
        s.save(state_dir: tmpdir)
      end

      expect(wait(baseline: base, ended_before: true).text).to eq("the first answer")
    end

    it "does not end on the settled turn while another runs; a turn that ends since still comes back" do
      # A message the user sent from the web in the gap starts before the
      # first look: the branch wants an idle session, so it waits on, and a
      # turn that ends since the baseline still comes back as the next reply.
      finish(outcome: "failed")
      base = baseline
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.status = "running"
      s.interrupted_turn = { "iteration" => 1, "enqueued_id" => "n1" }
      s.save(state_dir: tmpdir)
      later do
        write_reply("the new turn's answer")
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "idle"
        s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3), enqueued_id: "n1")
        s.save(state_dir: tmpdir)
      end

      expect(wait(baseline: base, ended_before: true).text).to eq("the new turn's answer")
    end
  end

  describe "with turn: (a queued message's own turn)" do
    let(:dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    def write_turn_reply(text, id)
      Samagotchi::SessionInbox.write_output(dir, text, enqueued_id: id)
      sleep(0.002)
    end

    def queue_input(id)
      Samagotchi::SessionInbox.write_input(dir, prompt: "later", enqueued_id: id, delivery: "queue")
    end

    # The worker takes the queued file for its turn.
    def claim(id)
      file = Samagotchi::SessionInbox.find_new_input_files(dir).find { |f| File.read(f).include?(id) }
      Samagotchi::SessionInbox.claim_input_file(file)
    end

    def end_turn(id, outcome: "completed", **facts)
      s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      s.status = "idle"
      s.last_turn = Samagotchi::LastTurn.new(outcome: outcome, ended_at: Time.now.iso8601(3), enqueued_id: id, **facts)
      s.save(state_dir: tmpdir)
    end

    def baseline = described_class.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))

    it "skips the running turn's reply and end, and returns its own reply" do
      queue_input("q1")
      base = baseline
      later do
        write_turn_reply("running answer", "r0")
        end_turn("r0")
        claim("q1")
        set(status: "running")
        looked(2)
        write_turn_reply("answer to q1", "q1")
        end_turn("q1")
      end

      result = wait(baseline: base, turn: "q1")
      expect(result.status).to eq(:done)
      expect(result.text).to eq("answer to q1")
      expect(result.file).to end_with("-q1.txt")
    end

    it "gives two queued turns each their own reply" do
      queue_input("q1")
      queue_input("q2")
      base = baseline
      later do
        claim("q1")
        write_turn_reply("one", "q1")
        end_turn("q1")
        claim("q2")
        set(status: "running")
        write_turn_reply("two", "q2")
        end_turn("q2")
      end

      first = Thread.new { wait(baseline: base, turn: "q1") }
      expect(wait(baseline: base, turn: "q2").text).to eq("two")
      expect(first.value.text).to eq("one")
    end

    it "ends on its own turn that left no reply (failed, canceled, empty) with that turn's outcome" do
      queue_input("q1")
      base = baseline
      later do
        end_turn("r0") # the running turn ends: not this wait's
        looked(2)
        claim("q1")
        end_turn("q1", outcome: "canceled", cancel_reason: "user")
      end

      result = wait(baseline: base, turn: "q1")
      expect(result.status).to eq(:no_reply)
      expect(result.outcome).to eq("canceled")
      expect(result.cancel_reason).to eq("user")
    end

    it "reports a turn canceled by a session stop (session_stopped) as canceled, like manual" do
      queue_input("q1")
      later do
        claim("q1")
        end_turn("q1", outcome: "canceled", cancel_reason: "session_stopped")
      end

      result = wait(baseline: baseline, turn: "q1")
      expect(result.to_h).to include(status: :no_reply, outcome: "canceled", cancel_reason: "session_stopped")
      expect(Samagotchi::ParentReport.json_line(result, session_id: session.id))
        .to include('"status":"canceled"', '"cancel_reason":"session_stopped"')
    end

    it "ends on its own end seen while a next queued turn already runs" do
      queue_input("q1")
      queue_input("q2")
      later do
        claim("q1")
        end_turn("q1", outcome: "failed")
        claim("q2")
        set(status: "running")
      end

      expect(wait(baseline: baseline, turn: "q1").outcome).to eq("failed")
    end

    it "does not take the running turn's question asked after the send: it waits on (here to its timeout)" do
      own_by_worker
      queue_input("q1")
      base = baseline
      later { set(pending_question: { id: "approve", kind: "approval", question: "Run rm?" }) }

      expect(wait(baseline: base, turn: "q1", timeout: 0.4).status).to eq(:timeout)
    end

    it "takes a question its own turn asks once its input is claimed" do
      own_by_worker
      queue_input("q1")
      base = baseline
      later do
        end_turn("r0")
        claim("q1")
        set(status: "running")
        looked(2)
        set(pending_question: { id: "mine", kind: "approval", question: "Run ls?" })
      end

      result = wait(baseline: base, turn: "q1")
      expect(result.status).to eq(:waiting_for_answer)
      expect(result.question).to have_attributes(id: "mine")
    end

    it "takes its own continue offer (no reply, asked after its end)" do
      own_by_worker
      queue_input("q1")
      base = baseline
      later do
        claim("q1")
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "idle"
        s.pending_question = { id: "cont", kind: "continue", question: "Continue?" }
        s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3), enqueued_id: "q1",
                                               exhausted: true, limit: 30)
        s.save(state_dir: tmpdir)
      end

      result = wait(baseline: base, turn: "q1")
      expect(result.status).to eq(:waiting_for_answer)
      expect(result.question).to have_attributes(id: "cont")
    end

    # A follow-up sent as a plain message (no queue) to a session that
    # looked idle: a turn starting at that moment may merge it as a steer,
    # and it never runs as a turn of its own.
    describe "an input another turn merged (a steer)" do
      def plain_input(id) = Samagotchi::SessionInbox.write_input(dir, prompt: "also", enqueued_id: id)

      def absorb(id, by:)
        claim(id)
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "running"
        s.interrupted_turn = { "iteration" => 1, "enqueued_id" => by }.compact
        s.save(state_dir: tmpdir)
      end

      before { set(status: "idle") }

      it "waits on the absorbing turn (another id): its question, then its reply, never a no_reply while it runs" do
        own_by_worker
        plain_input("y1")
        base = baseline
        later do
          absorb("y1", by: "a1")
          looked(2)
          set(pending_question: { id: "theirs", kind: "ask", question: "Which?" })
        end

        result = wait(baseline: base, turn: "y1")
        expect(result.to_h).to include(status: :waiting_for_answer)
        expect(result.question).to have_attributes(id: "theirs")

        later do
          set(pending_question: nil)
          write_turn_reply("a1 answer", "a1")
          end_turn("a1")
        end
        expect(wait(baseline: described_class.baseline_of(result.session, question_id: "theirs"), turn: "y1").text)
          .to eq("a1 answer")
      end

      it "waits on an absorbing turn with no id (a wake or reminder turn) from a worker that writes ids" do
        Samagotchi::WorkerSidecar.new(port: 1, features: %w[turn_ids]).write(dir)
        plain_input("y1")
        base = baseline
        later do
          absorb("y1", by: nil)
          looked(2)
          write_reply("wake answer")
          end_turn(nil)
        end

        expect(wait(baseline: base, turn: "y1").text).to eq("wake answer")
      end

      it "takes an absorbing turn that ran and ended between two looks (idle, a turn not its ended since)" do
        plain_input("y1")
        base = baseline
        claim("y1")
        write_reply("a1 answer")
        end_turn("a1")

        expect(wait(baseline: base, turn: "y1", timeout: 2).text).to eq("a1 answer")
      end

      it "never takes another turn for a queued input: taken, it waits through the idle moment before its own turn" do
        queue_input("q1")
        base = baseline
        later do
          write_turn_reply("x answer", "x0")
          end_turn("x0")
          claim("q1")
          looked(2) # the look between the claim and the turn's running save sees idle, last_turn x0
          run_q1 = Samagotchi::Session.load(session.id, state_dir: tmpdir)
          run_q1.status = "running"
          run_q1.interrupted_turn = { "iteration" => 1, "enqueued_id" => "q1" }
          run_q1.save(state_dir: tmpdir)
          write_turn_reply("q1 answer", "q1")
          end_turn("q1")
        end

        expect(wait(baseline: base, turn: "q1").text).to eq("q1 answer")
      end
    end

    # The turn a caller that sent nothing means (chi answer, chi send
    # --wait with no message): its input long taken.
    describe "on a turn already running or offered (own_turn)" do
      # The worker runs turn +id+: its checkpoint mark names it (nil: a
      # worker from before turn_ids).
      def run(id, pending_question: :keep)
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "running"
        s.interrupted_turn = { "started_at" => Time.now.iso8601(3), "iteration" => 1, "enqueued_id" => id }.compact
        s.pending_question = pending_question unless pending_question == :keep
        s.save(state_dir: tmpdir)
      end

      def offer(id, question_id: "cont")
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status = "idle"
        s.interrupted_turn = nil
        s.pending_question = { id: question_id, kind: "continue", question: "Continue?" }
        s.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: Time.now.iso8601(3), enqueued_id: id,
                                               exhausted: true, limit: 30)
        s.save(state_dir: tmpdir)
        sleep(0.002)
      end

      def sidecar(features)
        Samagotchi::WorkerSidecar.new(port: 1, features: features).write(dir)
      end

      def loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)

      describe ".own_turn" do
        it "is the running turn's, from its mark (no feature needed: only a new worker writes it)" do
          run("x1")
          expect(described_class.own_turn(loaded, session_dir: dir)).to eq("x1")
        end

        it "is nil for a running turn whose mark has no id (an older worker, a turn that ran no input)" do
          run(nil)
          expect(described_class.own_turn(loaded, session_dir: dir)).to be_nil
        end

        it "is the offer turn's while its continue offer stands, when the worker ties a continue turn to it" do
          offer("x1")
          sidecar(%w[delivery turn_ids])
          expect(described_class.own_turn(loaded, session_dir: dir)).to eq("x1")
        end

        it "is nil for an offer from a worker without turn_ids (its continue turn would carry no id)" do
          offer("x1")
          sidecar(["delivery"])
          expect(described_class.own_turn(loaded, session_dir: dir)).to be_nil
          FileUtils.rm_f(Samagotchi::WorkerSidecar.path(dir))
          expect(described_class.own_turn(loaded, session_dir: dir)).to be_nil
        end

        it "is nil for an idle session with no question, or another kind of question" do
          end_turn("x1")
          sidecar(["turn_ids"])
          expect(described_class.own_turn(loaded, session_dir: dir)).to be_nil
          set(pending_question: { id: "q", kind: "ask", question: "Which?" })
          expect(described_class.own_turn(loaded, session_dir: dir)).to be_nil
        end
      end

      it "returns the running turn's own reply, not a queued turn's newer one" do
        run("x1")
        base = baseline
        later do
          write_turn_reply("x1 answer", "x1")
          end_turn("x1")
          run("q1")
          write_turn_reply("q1 answer", "q1")
        end

        expect(wait(baseline: base, turn: "x1").text).to eq("x1 answer")
      end

      it "does not end on the exhausted turn's last_turn when its offer is answered from idle: the continue turn's reply comes" do
        own_by_worker
        offer("x1")
        base = described_class.baseline_of(loaded, question_id: "cont")
        later do
          run("x1", pending_question: nil)
          looked(2)
          write_turn_reply("continued", "x1")
          end_turn("x1")
        end

        result = wait(baseline: base, turn: "x1")
        expect(result.to_h).to include(status: :done, text: "continued")
      end

      it "takes a question the continue turn asks (its mark has the id last_turn already has)" do
        own_by_worker
        offer("x1")
        base = described_class.baseline_of(loaded, question_id: "cont")
        later { run("x1", pending_question: { id: "mine", kind: "approval", question: "Run ls?" }) }

        result = wait(baseline: base, turn: "x1")
        expect(result.to_h).to include(status: :waiting_for_answer)
        expect(result.question).to have_attributes(id: "mine")
      end

      it "does not take another turn's question: it waits on" do
        own_by_worker
        run("x1")
        base = baseline
        later do
          end_turn("other")
          run("q2", pending_question: { id: "theirs", kind: "approval", question: "Run rm?" })
        end

        # Its turn never recorded an end and another runs: lost, not that turn's question.
        expect(wait(baseline: base, turn: "x1", timeout: 2).to_h).to include(status: :no_reply, outcome: nil)
      end

      it "gives up on a lost turn (taken, another turn runs, last_turn not it) instead of sitting through the next" do
        run("x1")
        base = baseline
        # A new worker settled x1 (last_turn left alone) and runs q1.
        later { run("q1") }

        result = wait(baseline: base, turn: "x1", timeout: 2)
        expect(result.to_h).to include(status: :no_reply, outcome: nil)
      end

      it "is not lost while the next turn runs once its own end is recorded (last_turn looked at first)" do
        run("x1")
        base = baseline
        later do
          end_turn("x1", outcome: "failed")
          run("q1")
        end

        expect(wait(baseline: base, turn: "x1").outcome).to eq("failed")
      end

      it "ends with no reply when its turn ended without one and a next turn ran and ended between two looks" do
        run("x1")
        base = baseline
        later do
          end_turn("x1", outcome: "failed")
          run("q1")
          write_turn_reply("q1 answer", "q1")
          end_turn("q1")
        end

        result = wait(baseline: base, turn: "x1", poll_interval: 0.4, timeout: 3)
        expect(result.to_h).to include(status: :no_reply)
        expect(result.text).to be_nil
      end

      it "keeps the claimed rule for a mark with no id (a running worker from before): its question is the turn's" do
        own_by_worker
        run(nil)
        base = baseline
        later { run(nil, pending_question: { id: "mine", kind: "approval", question: "Run ls?" }) }

        expect(wait(baseline: base, turn: "x1").status).to eq(:waiting_for_answer)
      end
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
