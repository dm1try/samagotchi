# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/schedules"

# A Process::Status as a condition runner hands it back.
ConditionSpecStatus = Struct.new(:exitstatus)

# A schedule's condition (`--if CMD`, Schedules::ConditionPart,
# docs/scheduling.md "Conditions (--if)"): the store and its compat codec.
RSpec.describe Samagotchi::Schedules::ConditionPart do
  let(:now) { Time.utc(2026, 11, 25, 12) }

  around do |example|
    Dir.mktmpdir("schedules-condition") do |root|
      @dir = File.join(root, "sessions")
      example.run
    end
  end

  def session
    stamp = Time.now.utc.iso8601
    Samagotchi::Session.new(
      id: SecureRandom.uuid, mode: "assist", model_name: "main:m", working_directory: Dir.tmpdir,
      created_at: stamp, updated_at: stamp, status: "idle", messages: [{ role: "user", content: "the routine" }]
    ).tap { |saved| saved.save(state_dir: @dir) }
  end

  def store(clock: -> { now }) = Samagotchi::Schedules.new(state_dir: @dir, clock: clock)
  def every(interval) = Samagotchi::Schedules.recurrence(every: interval)
  def raw(schedules) = JSON.parse(File.read(schedules.path))
  def raw_entry(schedules, id) = raw(schedules)["schedules"].find { |entry| entry["id"] == id }

  # 0.188.0's Entry#due? (lib/samagotchi/schedules.rb at v0.188.0), on the
  # stored next_due as that chi reads it: the member as the file has it.
  def due_on_0_188?(stored, at)
    Time.iso8601(stored["next_due"].to_s) <= at
  rescue ArgumentError
    false
  end

  it "stores the owner's command with who set it and when, and reads it back with the real next_due" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "test -f /tmp/x")

    expect(entry.condition).to eq(cmd: "test -f /tmp/x", by: "cli", set_at: now.iso8601)
    stored = schedules.lookup(entry.id)
    expect(stored.condition).to eq(entry.condition)
    expect(stored.next_due).to eq((now + 300).utc.iso8601)
    expect(stored.extra).not_to have_key(described_class::CONDITION_NEXT_DUE)
  end

  # Compat N-1: 0.188.0 would fire a condition entry whatever CMD says. Its
  # due? can't parse a null next_due, so it never fires it; the entry still
  # reads (null is present, not missing) and stays enabled.
  it "hides next_due from 0.188.0, whose due? and format then never fire it but still read it" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")

    stored = raw_entry(schedules, entry.id)
    expect(stored["next_due"]).to be_nil
    expect(stored[described_class::CONDITION_NEXT_DUE]).to eq((now + 300).utc.iso8601)
    expect(stored["condition"]).to eq("cmd" => "exit 1", "by" => "cli", "set_at" => now.iso8601)
    [now + 300, now + (86_400 * 365)].each { |at| expect(due_on_0_188?(stored, at)).to be(false) }

    older = Samagotchi::StateFormat.new(
      version: Samagotchi::Schedules::VERSION,
      members: Samagotchi::Schedules::FORMAT.members.reject { |member| member.name == :condition },
      document_members: Samagotchi::Schedules::FORMAT.document_members
    )
    record = older.read(raw(schedules), collection: "schedules").entries.first
    expect(record).to be_readable
    expect(record.attributes).to include(next_due: nil, enabled: true)
    expect(record.extra).to include("condition", described_class::CONDITION_NEXT_DUE)
  end

  it "keeps the codec through every write: a change, an enable, a disable" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    schedules.disable(entry.id)
    schedules.enable(entry.id)
    schedules.edit(entry.id, title: "Gate")

    stored = raw_entry(schedules, entry.id)
    expect([stored["next_due"], stored[described_class::CONDITION_NEXT_DUE]]).to eq([nil, (now + 300).utc.iso8601])
    expect(schedules.lookup(entry.id)).to have_attributes(next_due: (now + 300).utc.iso8601, title: "Gate")
  end

  it "takes a real next_due an older chi wrote since over the hidden one" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    data = raw(schedules)
    data["schedules"].first["next_due"] = (now + 60).utc.iso8601
    File.write(schedules.path, JSON.generate(data))

    expect(schedules.lookup(entry.id).next_due).to eq((now + 60).utc.iso8601)
    schedules.edit(entry.id, title: "Gate")
    stored = raw_entry(schedules, entry.id)
    expect([stored["next_due"], stored[described_class::CONDITION_NEXT_DUE]]).to eq([nil, (now + 60).utc.iso8601])
  end

  it "drops the condition with --no-if, storing the real next_due again with no shadow key" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    edited = schedules.edit(entry.id, condition: :none)

    expect(edited.condition).to be_nil
    stored = raw_entry(schedules, entry.id)
    expect(stored["next_due"]).to eq((now + 300).utc.iso8601)
    expect(stored).not_to have_key(described_class::CONDITION_NEXT_DUE)
    expect(stored["condition"]).to be_nil
    expect(edited.history.last).to include(status: "edited", detail: "condition")
  end

  it "sets, changes and keeps a condition by its command on edit" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"))
    expect(raw_entry(schedules, entry.id)["next_due"]).to eq((now + 300).utc.iso8601)

    expect(schedules.edit(entry.id, condition: "exit 0").condition).to include(cmd: "exit 0", by: "cli")
    expect { schedules.edit(entry.id, condition: "exit 0") }.to raise_error(Samagotchi::Schedules::Usage, "nothing to change")
    expect(schedules.edit(entry.id, condition: "exit 1").condition[:cmd]).to eq("exit 1")
    expect { schedules.edit(entry.id, condition: :none) }.not_to raise_error
    expect { schedules.edit(entry.id, condition: :none) }.to raise_error(Samagotchi::Schedules::Usage, "nothing to change")
  end

  it "refuses a blank command, more than one line, more than 1 KiB, and a --date one-off either way" do
    schedules = store
    target = session.id
    date = Samagotchi::Schedules.recurrence(date: (now + 3600).localtime.strftime("%Y-%m-%dT%H:%M"))
    add = ->(cmd, recurrence: every("5m")) { schedules.add(target: target, prompt: "Check", recurrence: recurrence, condition: cmd) }

    expect { add.call("  ") }.to raise_error(Samagotchi::Schedules::Usage, "--if needs a command")
    ["a\nb", "a\rb", "a\0b"].each { |cmd| expect { add.call(cmd) }.to raise_error(Samagotchi::Schedules::Usage, /one line/) }
    expect { add.call("x" * 1025) }.to raise_error(Samagotchi::Schedules::Usage, /1025 bytes; the limit is 1024/)
    expect { add.call("x" * 1024) }.not_to raise_error
    expect { add.call("exit 0", recurrence: date) }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off can't have --if/)

    gated = schedules.add(target: target, prompt: "Other", recurrence: every("1h"), condition: "exit 0")
    expect { schedules.edit(gated.id, recurrence: date) }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off/)
    dated = schedules.add(target: target, prompt: "Once", recurrence: date)
    expect { schedules.edit(dated.id, condition: "exit 0") }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off/)
    expect(schedules.edit(gated.id, recurrence: date, condition: :none).condition).to be_nil
  end

  it "still protects the schedule's sessions while next_due is hidden" do
    schedules = store
    anchor = session.id
    schedules.add(target: anchor, prompt: "Check", recurrence: every("5m"), condition: "exit 1")

    expect(schedules.protected_ids).to include(anchor)
    expect(schedules.hold(anchor)).to have_attributes(reason: :scheduled)
  end

  it "keeps a condition that isn't an object as it is, still hiding next_due: it gates, never fires unchecked" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"))
    data = raw(schedules)
    data["schedules"].first["condition"] = "exit 0"
    File.write(schedules.path, JSON.generate(data))

    expect(schedules.lookup(entry.id).condition).to eq("exit 0")
    schedules.edit(entry.id, title: "Gate")
    expect(raw_entry(schedules, entry.id)).to include("next_due" => nil, "condition" => "exit 0")
  end

  describe "the tick" do
    # A runner that answers each CMD with +answers+ (cmd → exit code, or a
    # Run), and records what it was asked.
    def runner(answers, calls)
      lambda do |cmd, **options|
        calls << options.merge(cmd: cmd)
        answer = answers.fetch(cmd)
        answer = answer.call(options) if answer.respond_to?(:call)
        next answer if answer.is_a?(Samagotchi::ContextFetch::Run)

        Samagotchi::ContextFetch::Run.new(output: "busy idle 81s 145K\nmore\n", error: answer.zero? ? nil : "exit #{answer}",
                                          stderr: "", cancelled: false, status: ConditionSpecStatus.new(answer))
      end
    end

    def ticking(answers, calls = [], monotonic: -> { 0.0 })
      Samagotchi::Schedules.new(state_dir: @dir, clock: -> { now }, condition_runner: runner(answers, calls), monotonic: monotonic)
    end

    def continued(id)
      allow(Samagotchi::SessionContinue).to receive(:run).and_return(double(id: id, first_turn_id: "scheduled-turn"))
    end

    before { require "samagotchi/context_fetch" }

    it "fires on exit 0, running CMD in the target's folder with the schedule's env and the timeout" do
      calls = []
      target = session.id
      schedules = ticking({ "gate" => 0 }, calls)
      entry = schedules.add(target: target, prompt: "Check", recurrence: every("5m"), title: "Heartbeat", condition: "gate")
      continued(target)

      tick = schedules.tick(now: now + 300)
      expect(tick.outcomes.map(&:status)).to eq(%w[pending])
      expect(Samagotchi::SessionContinue).to have_received(:run).once
      expect(calls.size).to eq(1)
      expect(calls.first).to include(cmd: "gate", cwd: Dir.tmpdir, timeout: 30)
      expect(calls.first[:env]).to include("SAMAGOTCHI_SCHEDULE_ID" => entry.id, "SAMAGOTCHI_SCHEDULE_TITLE" => "Heartbeat",
                                           "SAMAGOTCHI_SCHEDULE_SESSION" => target, "SAMAGOTCHI_PARENT_SESSION" => nil)
    end

    it "moves a not-needed entry to its next occurrence and changes nothing else; another of its chain fires" do
      target = session.id
      schedules = ticking({ "gate" => 1 })
      gated = schedules.add(target: target, prompt: "Check", recurrence: every("5m"), condition: "gate")
      plain = schedules.add(target: target, prompt: "Other", recurrence: every("5m"))
      continued(target)
      before = schedules.lookup(gated.id)

      tick = schedules.tick(now: now + 300)
      expect(tick.outcomes.map { |outcome| [outcome.id, outcome.status] }).to contain_exactly([gated.id, "not-needed"], [plain.id, "pending"])
      expect(tick.outcomes.find { |outcome| outcome.id == gated.id }.detail).to eq("exit 1: busy idle 81s 145K")
      after = schedules.lookup(gated.id)
      expect(after.next_due).to eq((now + 600).utc.iso8601)
      expect(after.last_result).to eq("not needed: exit 1: busy idle 81s 145K")
      expect(after.to_h.except("next_due", "last_result")).to eq(before.to_h.except("next_due", "last_result"))
      expect(raw_entry(schedules, gated.id)["next_due"]).to be_nil
      expect(Samagotchi::SessionContinue).to have_received(:run).once
    end

    it "counts a condition that can't run as a failure, keeping the occurrence, and disables at max_failures" do
      calls = []
      schedules = ticking({ "nosuchcmd" => 127 }, calls)
      entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "nosuchcmd")

      first = schedules.tick(now: now + 300).outcomes.first
      expect([first.status, first.detail]).to eq(["failed", "condition: exit 127"])
      stored = schedules.lookup(entry.id)
      expect([stored.failures, stored.next_due, stored.history.last[:status]]).to eq([1, entry.next_due, "failed"])

      schedules.tick(now: now + 360)
      third = schedules.tick(now: now + 420).outcomes.first
      expect(third.disabled).to be(true)
      off = schedules.lookup(entry.id)
      expect([off.enabled, off.failures, off.disabled_notice[:kind]]).to eq([false, 3, "failed"])
      expect(calls.size).to eq(3)
    end

    it "says not needed before the busy check: a busy target spends no skip on an unneeded occurrence" do
      target = session.id
      Samagotchi::SessionInbox.write_input(Samagotchi::Session.session_dir(target, state_dir: @dir), prompt: "wait for me")
      no = ticking({ "no" => 1, "yes" => 0 })
      quiet = no.add(target: target, prompt: "Quiet", recurrence: every("5m"), condition: "no")
      busy = no.add(target: target, prompt: "Busy", recurrence: every("5m"), condition: "yes")

      outcomes = no.tick(now: now + 300).outcomes.to_h { |outcome| [outcome.id, outcome.status] }
      expect(outcomes).to eq(quiet.id => "not-needed", busy.id => "skipped")
      expect([no.lookup(quiet.id).skips, no.lookup(busy.id).skips]).to eq([0, 1])
    end

    it "misses a catch_up none entry a whole cycle late, whatever its CMD said" do
      calls = []
      schedules = ticking({ "gate" => 0 }, calls)
      entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), catch_up: "none", condition: "gate")

      outcome = schedules.tick(now: now + 900).outcomes.first
      expect(outcome.status).to eq("missed")
      expect(schedules.lookup(entry.id).next_due).to eq((now + 1200).utc.iso8601)
      expect(calls.size).to eq(1) # the pre-pass ran it; the main pass missed it first
    end

    it "runs no CMD on a dry run or a run-now" do
      calls = []
      target = session.id
      schedules = ticking({ "gate" => 1 }, calls)
      entry = schedules.add(target: target, prompt: "Check", recurrence: every("5m"), condition: "gate")
      continued(target)

      dry = schedules.tick(dry_run: true, now: now + 300).outcomes.first
      expect([dry.status, dry.detail]).to eq(["dry", "every 5m · if gate (not run)"])
      expect(schedules.run_now(entry.id).status).to eq("pending")
      expect(calls).to be_empty
    end

    it "leaves an entry whose condition or next_due changed since its CMD ran alone, with no outcome" do
      schedules = nil
      entry = nil
      answers = { "gate" => lambda { |_options|
        schedules.edit(entry.id, condition: "other")
        Samagotchi::ContextFetch::Run.new(output: "", error: nil, stderr: "", cancelled: false, status: ConditionSpecStatus.new(0))
      } }
      schedules = ticking(answers)
      entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "gate")
      allow(Samagotchi::SessionContinue).to receive(:run)

      expect(schedules.tick(now: now + 300).outcomes).to eq([])
      stored = schedules.lookup(entry.id)
      expect([stored.next_due, stored.failures, stored.condition[:cmd]]).to eq([entry.next_due, 0, "other"])
      expect(Samagotchi::SessionContinue).not_to have_received(:run)
    end

    it "fails a condition set by anyone but the CLI, or one that doesn't read, without running it" do
      calls = []
      schedules = ticking({}, calls)
      by = schedules.add(target: session.id, prompt: "One", recurrence: every("5m"), condition: "gate")
      odd = schedules.add(target: session.id, prompt: "Two", recurrence: every("5m"), condition: "gate")
      data = raw(schedules)
      data["schedules"].find { |stored| stored["id"] == by.id }["condition"]["by"] = "model"
      data["schedules"].find { |stored| stored["id"] == odd.id }["condition"] = "exit 0"
      File.write(schedules.path, JSON.generate(data))

      outcomes = schedules.tick(now: now + 300).outcomes.to_h { |outcome| [outcome.id, outcome.detail] }
      expect(outcomes).to eq(by.id => "condition: set by model: this chi runs only one set with chi schedule",
                             odd.id => "condition: it doesn't read (no command)")
      expect(calls).to be_empty
    end

    # H1 (schedules-if.review.md): a firing reserved with the pre-pass's
    # stale clock would look interrupted to a second ticker 35 s early.
    it "moves the tick's now on by the time the conditions took" do
      clock = [100.0]
      target = session.id
      answers = { "slow" => lambda { |_options|
        clock[0] += 35
        Samagotchi::ContextFetch::Run.new(output: "", error: nil, stderr: "", cancelled: false, status: ConditionSpecStatus.new(0))
      } }
      schedules = ticking(answers, monotonic: -> { clock.first })
      entry = schedules.add(target: target, prompt: "Check", recurrence: every("5m"), condition: "slow")
      continued(target)

      schedules.tick(now: now + 300)
      stored = schedules.lookup(entry.id)
      expect(stored.firing_since).to eq((now + 335).utc.iso8601)
      expect(stored.next_due).to eq((now + 635).utc.iso8601)
      expect(raw(schedules)["last_tick_at"]).to eq((now + 335).utc.iso8601)
    end

    it "keeps now as given when no condition is due" do
      clock = [100.0]
      schedules = ticking({}, monotonic: -> { clock[0] += 50 })
      schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"))

      schedules.tick(now: now + 10)
      expect(raw(schedules)["last_tick_at"]).to eq((now + 10).utc.iso8601)
    end

    it "records nothing for a cancelled CMD, and runs no more once cancelled" do
      calls = []
      stop = [false]
      answers = { "gate" => lambda { |_options|
        stop[0] = true
        Samagotchi::ContextFetch::Run.new(output: nil, error: nil, stderr: "", cancelled: true)
      } }
      schedules = ticking(answers, calls)
      one = schedules.add(target: session.id, prompt: "One", recurrence: every("5m"), condition: "gate")
      schedules.add(target: session.id, prompt: "Two", recurrence: every("5m"), condition: "gate")

      expect(schedules.tick(now: now + 300, cancelled: -> { stop.first }).outcomes).to eq([])
      expect(calls.size).to eq(1)
      expect(schedules.lookup(one.id)).to have_attributes(next_due: one.next_due, failures: 0)
    end

    context "with real commands (ContextFetch.run_command)" do
      def real
        Samagotchi::Schedules.new(state_dir: @dir, clock: -> { now })
      end

      it "gives the schedule's env and no parent session, the not-needed detail from stdout" do
        schedules = real
        entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"),
                              condition: 'printf "%s %s\\n" "$SAMAGOTCHI_SCHEDULE_ID" "${SAMAGOTCHI_PARENT_SESSION-unset}"; exit 3')
        outcome = with_env("SAMAGOTCHI_PARENT_SESSION" => "abc") { schedules.tick(now: now + 300).outcomes.first }
        expect([outcome.status, outcome.detail]).to eq(["not-needed", "exit 3: #{entry.id} unset"])
      end

      it "fails a missing command, the shell's words in the detail" do
        schedules = real
        schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "nosuchcmd-chi-spec")
        outcome = schedules.tick(now: now + 300).outcomes.first
        expect(outcome.status).to eq("failed")
        expect(outcome.detail).to start_with("condition: exit 127: ").and include("nosuchcmd-chi-spec")
      end
    end
  end
end
