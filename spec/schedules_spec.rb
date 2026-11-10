# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/schedules"
require "samagotchi/continue_intent"
require "samagotchi/memory_usage"
require "samagotchi/session_manager"

# Durable schedules (docs/scheduling.md): the store, the lock, the recurrence
# math, the tick, the busy check and the chain prune.
RSpec.describe Samagotchi::Schedules do
  def session(state_dir, parent: nil, continues: nil, status: "idle", delegate: false)
    now = Time.now.utc.iso8601
    Samagotchi::Session.new(
      id: SecureRandom.uuid, mode: "assist", model_name: "main:m", working_directory: Dir.tmpdir,
      created_at: now, updated_at: now, status: status, delegate: delegate, parent_id: parent,
      continues: continues, messages: [{ role: "user", content: "the routine" }]
    ).tap { |saved| saved.save(state_dir: state_dir) }
  end

  def archived?(state_dir, id)
    Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(id, state_dir: state_dir))
  end

  def every(interval)
    described_class.recurrence(every: interval)
  end

  def set_idle(state_dir, id)
    saved = Samagotchi::Session.load(id, state_dir: state_dir)
    saved.status = "idle"
    saved.save(state_dir: state_dir)
  end

  def complete_pending(state_dir, schedules, schedule_id)
    entry = schedules.lookup(schedule_id)
    return unless entry&.pending_turn_id

    finished_at = Time.iso8601(entry.firing_since) + 1
    saved = Samagotchi::Session.load(entry.pending_session_id, state_dir: state_dir)
    saved.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: finished_at.iso8601,
                                               enqueued_id: entry.pending_turn_id)
    saved.save(state_dir: state_dir)
    schedules.tick(now: Time.iso8601(entry.firing_since))
  end

  def store(state_dir, now: Time.now)
    described_class.new(state_dir: state_dir, clock: -> { now })
  end

  it "requires a format decision for every entry member" do
    declarations = described_class::FORMAT.members.to_h { |member| [member.name, member] }
    document_declarations = described_class::FORMAT.document_members.to_h { |member| [member.name, member] }

    expect(declarations.keys).to match_array(described_class::Entry.members)
    expect(declarations.values).to all(satisfy { |member| member.required? || member.defaulted? })
    expect(declarations.values.select(&:required?).map(&:name))
      .to match_array(%i[id anchor mode prompt recurrence next_due])
    expect(document_declarations.keys).to eq([:last_tick_at])
    expect(document_declarations.values).to all(satisfy { |member| member.defaulted? })
  end

  it "stamps the last acquired tick and warns only when the ticker is stale and auto-tick is off" do
    Dir.mktmpdir("schedules-last-tick") do |root|
      dir = File.join(root, "sessions")
      now = Time.utc(2026, 11, 10, 12)
      schedules = described_class.new(state_dir: dir, clock: -> { now })
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("schedule.auto_tick").and_return(false)
      allow(Samagotchi::Config).to receive(:get).with("schedule.tick_interval_minutes").and_return(5)

      expect(schedules.tick_warning(now: now)).to include("schedule.auto_tick: true", "chi schedule tick")
      schedules.tick(now: now)
      stamp = JSON.parse(File.read(schedules.path)).fetch("last_tick_at")
      expect(stamp).to eq(now.utc.iso8601)
      expect(schedules.tick_warning(now: now + 599)).to be_nil
      expect(schedules.tick_warning(now: now + 601)).to include("last 10 minutes")

      schedules.tick(dry_run: true, now: now + 601)
      expect(JSON.parse(File.read(schedules.path)).fetch("last_tick_at")).to eq(stamp)
      held = File.open(schedules.lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose
      held.flock(File::LOCK_EX)
      expect(schedules.tick(now: now + 601).locked).to be(true)
      held.flock(File::LOCK_UN)
      held.close
      expect(JSON.parse(File.read(schedules.path)).fetch("last_tick_at")).to eq(stamp)
      allow(Samagotchi::Config).to receive(:get).with("schedule.auto_tick").and_return(true)
      expect(schedules.tick_warning(now: now + 601)).to be_nil
    ensure
      if held && !held.closed?
        held.flock(File::LOCK_UN)
        held.close
      end
    end
  end

  it "writes every entry under the lock, so two writers in flight lose nothing" do
    Dir.mktmpdir("schedules-lock") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      # Both adds are in the file at once: each reads the list, pauses, then
      # writes. Without flock both threads read the same (empty) list and the
      # second write erases the first.
      allow(schedules).to receive(:read).and_wrap_original do |original|
        sleep 0.2 # sleep-ok: the overlap the lock is meant to prevent
        original.call
      end

      threads = %w[one two].map { |prompt| Thread.new { schedules.add(target: id, prompt: prompt, recurrence: every("1h")) } }
      threads.each(&:join)

      expect(schedules.entries.map(&:prompt).sort).to eq(%w[one two])
    end
  end

  it "waits for a lock another writer holds, and the tick reports it instead of firing" do
    Dir.mktmpdir("schedules-held-lock") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every("1m"))

      held = File.open(schedules.lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose, closed at the end
      held.flock(File::LOCK_EX)
      blocked = Thread.new { schedules.add(target: id, prompt: "later", recurrence: every("2h")) }
      sleep 0.2 # sleep-ok: the blocked thread's wait on the lock is the behaviour being tested
      expect(schedules.entries.map(&:prompt)).to eq(["Audit"])

      tick = schedules.tick(now: Time.now + 120)
      expect([tick.locked, tick.outcomes]).to eq([true, []])

      held.flock(File::LOCK_UN)
      blocked.join
      held.close

      expect(schedules.entries.map(&:prompt).sort).to eq(%w[Audit later])
      expect(schedules.lookup(entry.id).skips).to eq(0)
    end
  end

  it "keeps schedules.json beside the sessions dir, not inside it" do
    Dir.mktmpdir("schedules-location") do |root|
      dir = File.join(root, "sessions")
      schedules = described_class.new(state_dir: dir)
      id = session(dir).id
      schedules.add(target: id, prompt: "Audit", recurrence: every("1h"))

      expect(schedules.store_dir).to eq(File.expand_path(root))
      expect(schedules.path).to eq(File.join(File.expand_path(root), described_class::FILE))
      expect(schedules.lock_path).to eq(File.join(File.expand_path(root), described_class::LOCK))
      expect(File.exist?(schedules.path)).to be(true)
      expect(File.exist?(File.join(dir, described_class::FILE))).to be(false)

      # Nothing in the sessions dir looks like a session: MemoryUsage and the
      # listing see the one session, not the schedule file.
      sessions, unreadable = Samagotchi::MemoryUsage.load_sessions(state_dir: dir)
      expect([sessions.map(&:id), unreadable]).to eq([[id], 0])
    end
  end

  it "adds a weekday schedule due at the next local occurrence" do
    Dir.mktmpdir("schedules-weekday") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      entry = store(dir).add(target: id, prompt: "Audit", recurrence: described_class.recurrence(weekday: 1, time: "09:00"),
                             title: "Monday audit")

      expect(entry.mode).to eq(described_class::CHAIN)
      expect(entry.anchor).to eq(id)
      expect(entry.head).to eq(id)
      expect(entry.keep_links).to eq(5)
      expect(entry.recurrence_words).to eq("Mon 09:00")

      local = Time.now.localtime
      wanted = Time.local(local.year, local.month, local.day + ((1 - local.wday) % 7), 9, 0)
      wanted = Time.local(wanted.year, wanted.month, wanted.day + 7, 9, 0) if wanted <= Time.now
      expect(Time.iso8601(entry.next_due)).to eq(wanted)
    end
  end

  it "refuses a prompt that is blank or bigger than 16 KiB" do
    Dir.mktmpdir("schedules-prompt") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      expect { schedules.add(target: id, prompt: "   ", recurrence: every("1h")) }.to raise_error(described_class::Usage, /needs a prompt/)
      expect { schedules.add(target: id, prompt: "x" * 17_000, recurrence: every("1h")) }
        .to raise_error(described_class::Usage, /limit is 16 KiB/)
      expect(schedules.entries).to eq([])
    end
  end

  it "refuses a scratch session at add, not at the tick" do
    Dir.mktmpdir("schedules-scratch") do |root|
      dir = File.join(root, "sessions")
      scratch = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m", working_directory: Dir.tmpdir,
                                        created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601,
                                        scratch: true, messages: [])
      scratch.save(state_dir: dir)
      expect { store(dir).add(target: scratch.id, prompt: "x", recurrence: every("1h")) }
        .to raise_error(described_class::Usage, /scratch/)
    end
  end

  it "takes one recurrence kind, and weekday needs a time" do
    expect { described_class.recurrence }.to raise_error(described_class::Usage, /needs one of/)
    expect { described_class.recurrence(every: "1h", weekday: 1, time: "09:00") }.to raise_error(described_class::Usage, /not more/)
    expect { described_class.recurrence(weekday: 1) }.to raise_error(described_class::Usage, /needs time/)
    expect { described_class.recurrence(weekday: 9, time: "09:00") }.to raise_error(described_class::Usage, /1 \(Mon\) to 7/)
    expect { described_class.recurrence(weekday: "1abc", time: "09:00") }.to raise_error(described_class::Usage, /1 \(Mon\) to 7/)
    expect { described_class.recurrence(every: "1w") }.to raise_error(described_class::Usage, /every needs an interval/)
    expect { described_class.recurrence(date: "2026-13-01") }.to raise_error(described_class::Usage, /date must be/)
  end

  it "refuses an empty or zero interval rather than firing at every tick" do
    expect { described_class.recurrence(every: "") }.to raise_error(described_class::Usage, /needs one of every, weekday or date/)
    expect { described_class.recurrence(every: "  ") }.to raise_error(described_class::Usage, /needs one of every, weekday or date/)
    expect { described_class.recurrence(every: "0m") }.to raise_error(described_class::Usage, /every must be at least 1s, got 0m/)
    expect { described_class.recurrence(every: "0") }.to raise_error(described_class::Usage, /at least 1s/)
    expect { described_class.recurrence(every: "-5m") }.to raise_error(described_class::Usage, /every needs an interval/)

    # The guard behind the message: a zero never reaches next_due_for.
    expect(described_class.interval_seconds("0m")).to be_nil
    expect(described_class.interval_seconds("0")).to be_nil
    expect(described_class.interval_seconds("30m")).to eq(1800)

    # A field a model left empty is not a second recurrence kind.
    expect(described_class.recurrence(every: "", weekday: 1, time: "09:00")).to eq({ kind: "weekday", weekday: 1, time: "09:00" })
    expect(described_class.recurrence(every: "1h", weekday: "", time: "")).to eq({ kind: "every", interval: "1h" })
  end

  it "refuses to change a store it cannot read, rather than rewriting it" do
    Dir.mktmpdir("schedules-corrupt") do |root|
      dir = File.join(root, "sessions")
      schedules = store(dir)
      id = session(dir).id
      schedules.add(target: id, prompt: "Audit", recurrence: every("1h"))
      File.write(schedules.path, "{\"schedules\": [") # a truncated write

      before = File.read(schedules.path)
      expect(schedules.entries).to eq([]) # listing stays lenient
      expect { schedules.add(target: id, prompt: "Another", recurrence: every("2h")) }
        .to raise_error(described_class::Corrupt, /not readable JSON/)
      expect(schedules.cancel("Audit")).to be_nil
      expect(File.read(schedules.path)).to eq(before)
    end
  end

  it "does not rewrite a corrupt store when a tick tries to stamp last_tick_at" do
    Dir.mktmpdir("schedules-corrupt-tick") do |root|
      schedules = store(File.join(root, "sessions"))
      File.write(schedules.path, "{\"schedules\": [")
      before = File.read(schedules.path)
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      expect { schedules.tick(now: Time.utc(2026, 11, 10, 12)) }
        .to raise_error(described_class::Corrupt, /not readable JSON/)
      expect(Samagotchi::Log).to have_received(:warn).with(
        :worker, "store_unreadable", hash_including(error: "JSON::ParserError")
      )
      expect(File.read(schedules.path)).to eq(before)
    end
  end

  it "preserves a newer file and unknown keys through changes and ticks" do
    Dir.mktmpdir("schedules-unknown-keys") do |root|
      dir = File.join(root, "sessions")
      schedules = store(dir)
      id = session(dir).id
      entry = schedules.add(target: id, prompt: "Audit", recurrence: every("1m"), keep_links: 0)
      allow(Samagotchi::SessionContinue).to receive(:run).and_return(double(id: id, first_turn_id: "scheduled-turn"))

      data = JSON.parse(File.read(schedules.path))
      data["version"] = 2
      data["future_field"] = { "kept" => true }
      data["schedules"].first["future_field"] = ["whatever a later chi adds"]
      File.write(schedules.path, JSON.generate(data))

      schedules.disable(entry.id)
      schedules.enable(entry.id)
      expect(schedules.tick(now: Time.iso8601(entry.next_due) + 1).outcomes.first.status).to eq("pending")

      rewritten = JSON.parse(File.read(schedules.path))
      expect(rewritten["version"]).to eq(2)
      expect(rewritten["future_field"]).to eq("kept" => true)
      expect(rewritten["schedules"].first["future_field"]).to eq(["whatever a later chi adds"])
    end
  end

  it "defaults declared fields and keeps entries missing required fields through writes" do
    Dir.mktmpdir("schedules-missing-fields") do |root|
      dir = File.join(root, "sessions")
      schedules = store(dir)
      id = session(dir).id
      legacy = schedules.add(target: id, prompt: "Legacy", recurrence: every("1h"))
      current = schedules.add(target: id, prompt: "Current", recurrence: every("2h"))

      data = JSON.parse(File.read(schedules.path))
      legacy_data, unreadable_data = data["schedules"]
      legacy_data.delete("head")
      legacy_data.delete("skips")
      unreadable_data.delete("prompt")
      File.write(schedules.path, JSON.generate(data))

      warnings = []
      allow(Samagotchi::Log).to receive(:warn) { |*args| warnings << args }
      entries = schedules.entries
      expect(warnings.length).to eq(1)
      expect(warnings.first[0..1]).to eq([:worker, "schedule_entry_unreadable"])
      expect(warnings.first.last).to include(id: current.id, missing: ["prompt"])
      expect(entries.map(&:id)).to eq([legacy.id])
      expect([entries.first.head, entries.first.skips]).to eq([id, 0])

      warnings.clear
      schedules.disable(legacy.id)
      expect(warnings.length).to eq(2)
      rewritten = JSON.parse(File.read(schedules.path))
      expect(rewritten["schedules"].last).to eq(unreadable_data)
    end
  end

  it "adds nothing when the interval is zero" do
    Dir.mktmpdir("schedules-zero") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      expect { schedules.add(target: id, prompt: "Audit", recurrence: described_class.recurrence(every: "0m")) }
        .to raise_error(described_class::Usage, /at least 1s/)
      expect(schedules.entries).to eq([])
    end
  end

  it "keeps a weekday schedule on its wall clock across a DST change" do
    Dir.mktmpdir("schedules-dst") do |root|
      dir = File.join(root, "sessions")
      previous_zone = ENV["TZ"]
      ENV["TZ"] = "America/New_York"
      begin
        id = session(dir).id
        schedules = store(dir, now: Time.local(2026, 3, 5, 12, 0)) # Thursday before the fold
        entry = schedules.add(target: id, prompt: "Weekly", recurrence: described_class.recurrence(weekday: 1, time: "09:00"))
        due = Time.iso8601(entry.next_due)
        expect(due.localtime.strftime("%a %H:%M")).to eq("Mon 09:00")
        expect(due.localtime.to_date).to eq(Date.new(2026, 3, 9))

        # 02:30 on the spring-forward day does not exist: it fires at the
        # next valid minute.
        gap = described_class.local_moment(2026, 3, 8, 2, 30)
        expect(gap.localtime.strftime("%H:%M")).to eq("03:00")
      ensure
        ENV["TZ"] = previous_zone
      end
    end
  end

  it "matches Sunday with weekday 7: today when the time is still ahead, next week when it is past" do
    Dir.mktmpdir("schedules-sunday") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      # 2026-11-08 is a Sunday.
      schedules = store(dir, now: Time.local(2026, 11, 8, 12, 0))

      later = schedules.add(target: id, prompt: "Sunday later", recurrence: described_class.recurrence(weekday: 7, time: "18:00"))
      expect(Time.iso8601(later.next_due)).to eq(Time.local(2026, 11, 8, 18, 0))

      earlier = schedules.add(target: id, prompt: "Sunday earlier", recurrence: described_class.recurrence(weekday: 7, time: "09:00"))
      expect(Time.iso8601(earlier.next_due)).to eq(Time.local(2026, 11, 15, 9, 0))
      expect(earlier.recurrence_words).to eq("Sun 09:00")
    end
  end

  it "keeps a Sunday schedule on its wall clock across a DST change" do
    Dir.mktmpdir("schedules-sunday-dst") do |root|
      dir = File.join(root, "sessions")
      previous_zone = ENV["TZ"]
      ENV["TZ"] = "America/New_York"
      begin
        id = session(dir).id
        schedules = store(dir, now: Time.local(2026, 3, 5, 12, 0)) # Thursday before the fold
        entry = schedules.add(target: id, prompt: "Sunday", recurrence: described_class.recurrence(weekday: 7, time: "09:00"))
        due = Time.iso8601(entry.next_due)
        expect(due.localtime.strftime("%a %H:%M")).to eq("Sun 09:00")
        expect(due.localtime.to_date).to eq(Date.new(2026, 3, 8))
      ensure
        ENV["TZ"] = previous_zone
      end
    end
  end

  it "refuses an ambiguous prefix or title, naming the schedules that match" do
    Dir.mktmpdir("schedules-ambiguous") do |root|
      dir = File.join(root, "sessions")
      # Only the schedule ids are fixed (AtomicFile's temp names also use hex).
      fixed = %w[a1b2c3d4e5f6a7b8 a1b2c3d4e5f6a7c9]
      allow(SecureRandom).to receive(:hex).and_wrap_original do |original, length|
        length == 8 ? fixed.shift : original.call(length)
      end
      id = session(dir).id
      schedules = store(dir)
      first = schedules.add(target: id, prompt: "One", recurrence: every("1h"), title: "Audit")
      schedules.disable(first.id) # a disabled entry is not a duplicate, but it still answers a lookup
      schedules.add(target: id, prompt: "Two", recurrence: every("2h"), title: "Audit")

      expect(schedules.lookup("a1b2c3d4e5f6a7b8").prompt).to eq("One")
      expect(schedules.lookup("a1b2c3d4e5f6a7b").id).to eq(first.id)

      expect { schedules.lookup("a1b2c3") }.to raise_error(described_class::Usage,
                                                           /a1b2c3 matches 2 schedules: a1b2c3d4e5f6a7b8, a1b2c3d4e5f6a7c9/)
      expect { schedules.cancel("a1b2c3") }.to raise_error(described_class::Usage, /matches 2 schedules/)
      expect { schedules.disable("Audit") }.to raise_error(described_class::Usage, /Audit matches 2 schedules/)
      expect(schedules.entries(include_disabled: true).size).to eq(2)

      # A full id still resolves.
      expect(schedules.enable("a1b2c3d4e5f6a7c9").id).to eq("a1b2c3d4e5f6a7c9")
    end
  end

  it "fires a chain entry once, archiving the previous link and moving the head" do
    Dir.mktmpdir("schedules-chain") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit the queue", recurrence: every("1m"))

      fired = schedules.tick(now: Time.now + 60).outcomes.first
      expect(fired.status).to eq("pending")
      expect(fired.detail).to start_with("new link")

      stored = schedules.lookup(entry.id)
      expect(stored.head).to eq(fired.entry.head)
      expect(archived?(dir, anchor)).to be(true)
      expect(Samagotchi::Session.load(stored.head, state_dir: dir).continues).to eq(anchor)
      # The link's first turn is the schedule's (its origin, ClientId.schedule).
      expect(Samagotchi::Session.load(stored.head, state_dir: dir).first_turn_client_id).to eq("system:schedule:#{entry.id}")
      expect(stored.failures).to eq(0)
      expect(stored.skips).to eq(0)
      expect(Time.iso8601(stored.next_due)).to be > Time.now
    end
  end

  # An entry stored before the add refused a ! prompt: its firing would be
  # refused at the link's intake, so it fails here instead, starting no link
  # and archiving nothing, and counts toward max_failures.
  it "fails a stored chain entry whose prompt is a shell line, starting no link" do
    Dir.mktmpdir("schedules-chain-shell") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "touch x", recurrence: every("1m"))
      file = File.join(root, "schedules.json")
      File.write(file, File.read(file).sub('"prompt": "touch x"', '"prompt": "!touch x"'))
      expect(schedules.lookup(entry.id).prompt).to eq("!touch x")

      fired = schedules.tick(now: Time.now + 60).outcomes.first

      expect(fired).to have_attributes(status: "failed", detail: Samagotchi::CommandIntake::REFUSED)
      expect(Samagotchi::Session.list(state_dir: dir).map(&:id)).to eq([anchor])
      expect(archived?(dir, anchor)).to be(false)
      expect(schedules.lookup(entry.id).failures).to eq(1)
    end
  end

  # Its Bridge would refuse it, but a delivery that falls back to the input
  # file is accepted: it fails before any delivery instead.
  it "fails a stored same-mode entry whose prompt is a shell line, delivering nothing" do
    Dir.mktmpdir("schedules-same-shell") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "touch x", recurrence: every("1m"), mode: "same")
      file = File.join(root, "schedules.json")
      File.write(file, File.read(file).sub('"prompt": "touch x"', '"prompt": "!touch x"'))
      allow(Samagotchi::SessionManager).to receive(:deliver_turn)

      fired = schedules.tick(now: Time.now + 60).outcomes.first

      expect(fired).to have_attributes(status: "failed", detail: Samagotchi::CommandIntake::REFUSED)
      expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, head: anchor)
    end
  end

  it "fires one entry per chain per tick, and retries the other at the next one" do
    Dir.mktmpdir("schedules-chain-once") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      first = schedules.add(target: anchor, prompt: "Audit", title: "Audit", recurrence: every("5m"))
      second = schedules.add(target: anchor, prompt: "Check the build", title: "Check", recurrence: every("5m"))
      due = first.next_due # both were added at the same clock, so both are due now

      tick = schedules.tick(now: Time.now + 300)
      expect(tick.outcomes.map(&:status).sort).to eq(%w[pending skipped])
      fired = tick.outcomes.find { |outcome| outcome.status == "pending" }
      held = tick.outcomes.find { |outcome| outcome.status == "skipped" }
      expect(held.id).to eq([first.id, second.id].reject { |id| id == fired.id }.first)
      expect(held.detail).to eq("the chain just fired; retry at the next tick")

      # The link the first firing made is still standing: the second entry did
      # not continue it and archive it before its prompt ever ran.
      link = schedules.lookup(fired.id).head
      expect(archived?(dir, link)).to be(false)
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(2)

      # The skip is not a lost occurrence: the clock stayed at the moment the
      # tick tried.
      held_entry = schedules.lookup(held.id)
      expect([held_entry.skips, held_entry.failures, held_entry.next_due, held_entry.head, held_entry.enabled])
        .to eq([1, 0, due, anchor, true])

      # Another tick cannot continue the new link while its schedule turn is
      # still in flight, even if the worker has gone idle.
      set_idle(dir, link)
      again = schedules.tick(now: Time.now + 420)
      expect(again.outcomes.map(&:status)).to eq(%w[pending skipped])
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(2)
      expect(again.outcomes.find { |outcome| outcome.status == "skipped" }.detail)
        .to eq("a schedule turn is still pending in this chain")
    end
  end

  # The tick's dominant cost is the chain walk: every entry's target, its
  # chain key and its busy check resolve over one SessionChain::Links.
  it "lists the sessions once for a whole tick's checks" do
    Dir.mktmpdir("schedules-one-listing") do |root|
      dir = File.join(root, "sessions")
      first = session(dir)
      Samagotchi::ArchiveStore.archive(first.id, state_dir: dir)
      head = session(dir, continues: first.id).id
      other = session(dir).id
      schedules = store(dir)
      schedules.add(target: first.id, prompt: "Audit", recurrence: every("1m"))
      schedules.add(target: head, prompt: "Check", recurrence: every("1m"), mode: "same")
      schedules.add(target: other, prompt: "Sweep", recurrence: every("1m"))

      expect(Samagotchi::Session).to receive(:list).once.and_call_original
      tick = schedules.tick(dry_run: true, now: Time.now + 60)

      expect(tick.outcomes.map(&:status)).to eq(%w[dry dry dry])
    end
  end

  it "takes the earliest due entry first, so a chain's entries take turns" do
    Dir.mktmpdir("schedules-fair") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      # Added in this order, due at the same moment: file order would fire the
      # first one every tick and starve the other two into max_skips.
      a = schedules.add(target: anchor, prompt: "A", title: "A", recurrence: every("1m"))
      b = schedules.add(target: anchor, prompt: "B", title: "B", recurrence: every("1m"))
      c = schedules.add(target: anchor, prompt: "C", title: "C", recurrence: every("1m"))
      now = Time.now + 60

      fired = []
      3.times do |round|
        tick = schedules.tick(now: now + (round * 60))
        turns = tick.outcomes.select { |outcome| outcome.status == "pending" }
        fired.concat(turns.map(&:title))
        tick.outcomes.each do |outcome|
          set_idle(dir, schedules.lookup(outcome.id).head) if outcome.status == "pending"
        end
        turns.each { |outcome| complete_pending(dir, schedules, outcome.id) }
      end

      expect(fired.uniq.sort).to eq(%w[A B C])
      [a, b, c].each do |added|
        entry = schedules.lookup(added.id)
        expect(entry.enabled).to be(true)
        expect(entry.skips).to be < entry.max_skips
      end
      # One line: the three firings continue each other, not three separate
      # chains hanging off the anchor.
      chain = []
      id = Samagotchi::SessionChain.latest(anchor, state_dir: dir)
      while id
        chain << id
        id = Samagotchi::Session.load(id, state_dir: dir).continues
      end
      expect(chain.size).to eq(4)
      expect(chain).to include(*schedules.entries.map(&:head))
    end
  end

  it "changes nothing on --dry-run" do
    Dir.mktmpdir("schedules-dry") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      before = schedules.lookup(entry.id)

      tick = schedules.tick(dry_run: true, now: Time.now + 60)
      expect(tick.outcomes.map(&:status)).to eq(["dry"])
      expect(schedules.lookup(entry.id)).to eq(before)
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(1)
    end
  end

  # C1: a chain firing that finds the head's last link still starting (a
  # firing of another ticker just continued it) waits for the next tick.
  it "skips a chain firing whose last link's worker is still starting" do
    Dir.mktmpdir("schedules-starting") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      Samagotchi::StartingMarker.mark(anchor, state_dir: dir)

      tick = schedules.tick(now: Time.now + 120)

      expect(tick.outcomes.map(&:status)).to eq(["skipped"])
      expect(tick.outcomes.first.detail).to eq("its worker is starting or leaving")
      # Between the busy check and the firing, the archive refuses it the same way.
      expect(Samagotchi::Schedules::SKIP_REASONS).to include("starting", "starting_child")
    end
  end

  it "leaves next_due alone when the target is busy, and disables after max_skips" do
    Dir.mktmpdir("schedules-skip") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      due = entry.next_due
      Samagotchi::SessionInbox.write_input(Samagotchi::Session.session_dir(anchor, state_dir: dir), prompt: "wait for me")

      3.times do
        tick = schedules.tick(now: Time.now + 120)
        expect(tick.outcomes.first.status).to eq("skipped")
      end
      expect(schedules.lookup(entry.id).skips).to eq(3)
      expect(schedules.lookup(entry.id).next_due).to eq(due)

      9.times { schedules.tick(now: Time.now + 120) }
      disabled = schedules.lookup(entry.id)
      expect(disabled.enabled).to be(false)
      expect(disabled.last_result).to start_with("disabled:")
      expect(schedules.entries).to eq([])
      expect(schedules.entries(include_disabled: true).size).to eq(1)
    end
  end

  it "resets skips and failures when a firing succeeds" do
    Dir.mktmpdir("schedules-reset") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), max_skips: 3)
      inbox = Samagotchi::Session.session_dir(anchor, state_dir: dir)
      Samagotchi::SessionInbox.write_input(inbox, prompt: "queued")
      schedules.tick(now: Time.now + 120)
      schedules.tick(now: Time.now + 120)
      expect(schedules.lookup(entry.id).skips).to eq(2)
      Samagotchi::SessionInbox.find_new_input_files(inbox).each { |file| File.delete(file) }
      schedules.tick(now: Time.now + 120)
      complete_pending(dir, schedules, entry.id)
      after = schedules.lookup(entry.id)
      expect([after.skips, after.failures, after.enabled]).to eq([0, 0, true])
    end
  end

  it "moves to the next occurrence with catch_up none when a whole cycle has passed" do
    Dir.mktmpdir("schedules-catchup") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1h"), catch_up: "none")
      ticked = Time.now + 7800
      tick = schedules.tick(now: ticked)
      expect(tick.outcomes.first.status).to eq("missed")
      after = schedules.lookup(entry.id)
      expect(after.last_result).to eq("missed")
      expect(Time.iso8601(after.next_due)).to be > ticked
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(1)
    end
  end

  it "fires a catch_up none entry that is only a tick late" do
    Dir.mktmpdir("schedules-catchup-late-tick") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      monday = Time.local(2026, 11, 2, 8, 50) # 2026-11-02 is a Monday
      anchor = session(dir).id
      schedules = store(dir, now: monday)
      entry = schedules.add(target: anchor, prompt: "Audit", catch_up: "none",
                            recurrence: described_class.recurrence(weekday: 1, time: "09:00"))
      expect(Time.iso8601(entry.next_due)).to eq(Time.local(2026, 11, 2, 9, 0))

      # 20 minutes late: the next Monday is still ahead, so this is a late tick,
      # not a missed cycle, and the schedule runs.
      tick = schedules.tick(now: Time.local(2026, 11, 2, 9, 20))
      expect(tick.outcomes.first.status).to eq("pending")
      after = schedules.lookup(entry.id)
      expect(after.last_result).to start_with("new link")
      expect(Time.iso8601(after.next_due)).to eq(Time.local(2026, 11, 9, 9, 0))
    end
  end

  it "misses a catch_up none weekday schedule a whole cycle late and moves it to the next one" do
    Dir.mktmpdir("schedules-catchup-cycle") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir, now: Time.local(2026, 11, 2, 8, 50))
      entry = schedules.add(target: anchor, prompt: "Audit", catch_up: "none",
                            recurrence: described_class.recurrence(weekday: 1, time: "09:00"))

      # The machine was asleep all week: the tick finds Monday's occurrence and
      # the one after it already past.
      tick = schedules.tick(now: Time.local(2026, 11, 9, 9, 30))
      expect(tick.outcomes.first.status).to eq("missed")
      after = schedules.lookup(entry.id)
      expect([after.last_result, Time.iso8601(after.next_due)])
        .to eq(["missed", Time.local(2026, 11, 16, 9, 0)])
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(1)
    end
  end

  it "fires a `date` one-off late with catch_up none: there is no next occurrence to compare" do
    Dir.mktmpdir("schedules-catchup-date") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      at = Time.local(2026, 11, 20, 9, 0)
      anchor = session(dir).id
      schedules = store(dir, now: at + 3600)
      entry = schedules.add(target: anchor, prompt: "One thing", catch_up: "none",
                            recurrence: described_class.recurrence(date: "2026-11-20T09:00"))

      outcome = schedules.tick(now: at + 3600).outcomes.first
      expect(outcome.status).to eq("pending")
      after = schedules.lookup(entry.id)
      expect([after.enabled, after.next_due, after.last_result]).to eq([false, nil, "new link #{after.head[0, 8]}"])
    end
  end

  it "counts a skip, not a failure, when a delegate child is running" do
    Dir.mktmpdir("schedules-child") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      child = session(dir, parent: anchor, delegate: true, status: Samagotchi::Session::STATUS_RUNNING)
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(child.id, state_dir: dir), kind: "tui")

      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect(outcome.status).to eq("skipped")
      expect(outcome.detail).to include(child.id[0, 8])
      after = schedules.lookup(entry.id)
      expect([after.failures, after.skips]).to eq([0, 1])
      lock.release
    end
  end

  it "fails and disables after max_failures against a gone session" do
    Dir.mktmpdir("schedules-failures") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), max_failures: 3)
      FileUtils.rm_f(Samagotchi::Session.session_file(anchor, state_dir: dir))
      FileUtils.rm_rf(Samagotchi::Session.session_dir(anchor, state_dir: dir))

      3.times do
        tick = schedules.tick(now: Time.now + 120)
        expect(tick.outcomes.first.status).to eq("failed")
      end
      after = schedules.lookup(entry.id)
      expect([after.failures, after.enabled]).to eq([3, false])
      expect(schedules.entries).to eq([])
    end
  end

  it "prunes the links behind the kept window with their delegates, never the anchor" do
    Dir.mktmpdir("schedules-prune") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 3)

      schedules.tick(now: Time.now + 120)
      first = schedules.lookup(entry.id).head
      complete_pending(dir, schedules, entry.id)
      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      # Three more firings: run_now fires whatever the clock says, so the
      # window is tested against a real chain length.
      3.times do
        set_idle(dir, schedules.lookup(entry.id).head)
        schedules.run_now(entry.id)
        complete_pending(dir, schedules, entry.id)
      end

      head = schedules.lookup(entry.id).head
      ids = Samagotchi::Session.list(state_dir: dir, include_archived: true).map(&:id)
      expect(ids).to include(anchor, head)
      expect(ids).not_to include(first)
      expect(ids).not_to include(child.id)
      expect(Samagotchi::SessionChain.latest(head, state_dir: dir)).to eq(head)
    end
  end

  it "never prunes the links that came before the schedule's anchor" do
    Dir.mktmpdir("schedules-anchor-history") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      root = session(dir).id
      middle = session(dir, continues: root).id
      anchor = session(dir, continues: middle).id
      # The user's own history, archived before the schedule ever existed.
      Samagotchi::ArchiveStore.archive(root, state_dir: dir)
      Samagotchi::ArchiveStore.archive(middle, state_dir: dir)

      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 2)
      4.times do |step|
        set_idle(dir, schedules.lookup(entry.id).head)
        expect(schedules.tick(now: Time.now + 120 + (step * 120)).outcomes.first.status).to eq("pending")
        complete_pending(dir, schedules, entry.id)
      end

      ids = Samagotchi::Session.list(state_dir: dir, include_archived: true).map(&:id)
      expect(ids).to include(root, middle, schedules.lookup(entry.id).head)

      # The head still walks its own chain: the pruned links are behind it,
      # never in front of it.
      head = schedules.lookup(entry.id).head
      expect(Samagotchi::SessionChain.latest(head, state_dir: dir)).to eq(head)
    end
  end

  it "deletes a delegate before the link above it, so a refused child leaves that link standing" do
    Dir.mktmpdir("schedules-prune-order") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 1)

      schedules.tick(now: Time.now + 120)
      first = schedules.lookup(entry.id).head
      complete_pending(dir, schedules, entry.id)
      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      # The child's delete is refused (its worker is still there).
      allow(Samagotchi::SessionManager).to receive(:delete_session).and_call_original
      allow(Samagotchi::SessionManager).to receive(:delete_session).with(child.id, state_dir: dir) do
        raise Samagotchi::SessionManager::DeleteRefused.new(child.id, :worker_running)
      end

      set_idle(dir, first)
      outcome = schedules.tick(now: Time.now + 240).outcomes.first
      expect(outcome.status).to eq("pending")
      complete_pending(dir, schedules, entry.id)

      # Children first: the child does not go, so its link is untouched and
      # still archived. Deleting the link first would leave a delegate under
      # a link that no longer exists, unreachable by the next firing.
      expect(archived?(dir, first)).to be(true)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(true)
      expect(schedules.lookup(entry.id).failures).to eq(0)
    end
  end

  it "leaves a link whose subtree still has a worker, and prunes it once the worker is gone" do
    Dir.mktmpdir("schedules-prune-owner") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 2)

      schedules.tick(now: Time.now + 120)
      first = schedules.lookup(entry.id).head          # still inside the window
      complete_pending(dir, schedules, entry.id)
      set_idle(dir, first)
      schedules.tick(now: Time.now + 240)
      complete_pending(dir, schedules, entry.id)
      head = schedules.lookup(entry.id).head

      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(child.id, state_dir: dir), kind: "worker")

      # This firing pushes `first` out of the window: its subtree has a worker,
      # so nothing in it is deleted.
      set_idle(dir, head)
      expect(schedules.tick(now: Time.now + 480).outcomes.first.status).to eq("pending")
      complete_pending(dir, schedules, entry.id)
      # Nothing in that subtree is deleted while a worker owns part of it.
      expect(archived?(dir, first)).to be(true)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(true)

      lock.release
      set_idle(dir, schedules.lookup(entry.id).head)
      schedules.run_now(entry.id)
      complete_pending(dir, schedules, entry.id)
      expect(archived?(dir, first)).to be(false)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(false)
    end
  end

  it "prunes a link only when its whole subtree is archived" do
    Dir.mktmpdir("schedules-prune-open") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 2)

      schedules.tick(now: Time.now + 120)
      first = schedules.lookup(entry.id).head
      complete_pending(dir, schedules, entry.id)
      child = session(dir, parent: first, delegate: true)
      set_idle(dir, first)
      schedules.tick(now: Time.now + 240) # archives `first` and its delegate
      complete_pending(dir, schedules, entry.id)
      Samagotchi::ArchiveStore.unarchive(child.id, state_dir: dir)

      # `first` is now behind the window, but one of its descendants is not
      # archived: nothing in that subtree is deleted.
      set_idle(dir, schedules.lookup(entry.id).head)
      expect(schedules.tick(now: Time.now + 360).outcomes.first.status).to eq("pending")
      complete_pending(dir, schedules, entry.id)
      expect(archived?(dir, first)).to be(true)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(true)

      # Archive the delegate too and the whole subtree goes, children first.
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      set_idle(dir, schedules.lookup(entry.id).head)
      schedules.run_now(entry.id)
      complete_pending(dir, schedules, entry.id)
      expect(archived?(dir, first)).to be(false)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(false)
    end
  end

  it "keeps everything with keep_links 0" do
    Dir.mktmpdir("schedules-keep-all") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 0)
      3.times do |step|
        set_idle(dir, schedules.lookup(entry.id).head)
        expect(schedules.tick(now: Time.now + 120 + (step * 120)).outcomes.first.status).to eq("pending")
        complete_pending(dir, schedules, entry.id)
      end
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(4)
    end
  end

  it "stops pruning when an archived link still has a worker, and records no failure" do
    Dir.mktmpdir("schedules-prune-stop") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), keep_links: 2)
      schedules.tick(now: Time.now + 120)
      first = schedules.lookup(entry.id).head
      complete_pending(dir, schedules, entry.id)
      set_idle(dir, first)
      schedules.tick(now: Time.now + 240)
      complete_pending(dir, schedules, entry.id)
      # `first` is archived now but still inside the window; the next firing
      # pushes it out, and its worker refuses the delete.
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(first, state_dir: dir), kind: "worker")
      set_idle(dir, schedules.lookup(entry.id).head)
      outcome = schedules.tick(now: Time.now + 360).outcomes.first
      expect(outcome.status).to eq("pending")
      complete_pending(dir, schedules, entry.id)
      after = schedules.lookup(entry.id)
      expect(after.failures).to eq(0)
      expect(archived?(dir, first)).to be(true)
      lock.release
      set_idle(dir, schedules.lookup(entry.id).head)
      fired = schedules.run_now(entry.id)
      expect(fired.status).to eq("pending")
      complete_pending(dir, schedules, entry.id)
      expect(archived?(dir, first)).to be(false)
    end
  end

  it "fires a same-mode entry by queueing a turn" do
    Dir.mktmpdir("schedules-same") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check the queue", recurrence: every("1m"), mode: described_class::SAME)
      delivered = nil
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, prompt:, **kwargs|
        delivered = { id: id, prompt: prompt, delivery: kwargs[:delivery], client_id: kwargs[:client_id] }
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file, ack: { "enqueued_id" => "scheduled-turn" })
      end
      tick = schedules.tick(now: Time.now + 120)
      expect(tick.outcomes.first.status).to eq("pending")
      expect(delivered[:delivery]).to eq(Samagotchi::Delivery::QUEUE)
      expect(delivered[:client_id]).to eq(Samagotchi::ClientId.schedule(entry.id))
      expect(schedules.lookup(entry.id).last_result).to eq("queued a turn")
    end
  end

  # Pick 1 (R3, Q1): a schedule respects a stop, in both modes: a skip
  # (the stop's own words), nothing delivered, the stop kept.
  it "skips an entry whose session its owner stopped, in both modes" do
    Dir.mktmpdir("schedules-stopped") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      same = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: described_class::SAME)
      chain = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      Samagotchi::Session.mark_stopped(anchor, state_dir: dir)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn)
      allow(Samagotchi::SessionContinue).to receive(:run)

      outcomes = schedules.tick(now: Time.now + 120).outcomes

      detail = Samagotchi::SessionManager::DeliverResult::STOPPED["detail"]
      expect(outcomes.map { |o| [o.id, o.status, o.detail] })
        .to contain_exactly([same.id, "skipped", detail], [chain.id, "skipped", detail])
      expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
      expect(Samagotchi::SessionContinue).not_to have_received(:run)
      expect(Samagotchi::Session.stopped_marker?(anchor, state_dir: dir)).to be(true)
      expect(schedules.lookup(same.id)).to have_attributes(skips: 1, failures: 0)
    end
  end

  # A stop that lands between the tick's check and the firing: deliver_turn
  # refuses the schedule's wake, and that counts as a skip, not a failure.
  it "counts a same-mode firing deliver_turn refused as stopped as a skip" do
    Dir.mktmpdir("schedules-stopped-race") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: described_class::SAME)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :refused, code: 409,
                                                      ack: Samagotchi::SessionManager::DeliverResult::STOPPED)
      )

      outcome = schedules.tick(now: Time.now + 120).outcomes.first

      expect(outcome).to have_attributes(status: "skipped", detail: Samagotchi::SessionManager::DeliverResult::STOPPED["detail"])
      expect(schedules.lookup(entry.id)).to have_attributes(skips: 1, failures: 0)
    end
  end

  it "waits for the tick lock and does not fire an entry the tick already reserved" do
    Dir.mktmpdir("schedules-run-now-lock") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      fired = 0
      allow(Samagotchi::SessionContinue).to receive(:run) do
        fired += 1
        double(id: anchor, first_turn_id: "scheduled-turn")
      end

      held = File.open(schedules.lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- fake tick holds the lock
      held.flock(File::LOCK_EX)
      running = Thread.new { schedules.run_now(entry.id) }
      sleep 0.2 # sleep-ok: run-now must wait for the fake tick's lock
      expect(running).to be_alive

      data = JSON.parse(File.read(schedules.path))
      data["schedules"].first.merge!(
        "due_was" => entry.next_due,
        "firing_since" => Time.iso8601(entry.next_due).utc.iso8601,
        "next_due" => (Time.iso8601(entry.next_due) + 60).utc.iso8601
      )
      File.write(schedules.path, JSON.generate(data))
      held.flock(File::LOCK_UN)
      held.close

      join!(running, "run-now reservation")
      outcome = running.value
      expect(outcome.status).to eq("pending")
      expect(outcome.detail).to include("already firing")
      expect(fired).to eq(0)
    ensure
      if held && !held.closed?
        held.flock(File::LOCK_UN)
        held.close
      end
      join!(running, "run-now reservation") if running
    end
  end

  it "refuses to wake an archived session in same mode" do
    Dir.mktmpdir("schedules-archived") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Wake", recurrence: every("1m"), mode: described_class::SAME)
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect([outcome.status, outcome.detail]).to eq(%w[failed archived])
      after = schedules.lookup(entry.id)
      expect(after.failures).to eq(1)
      expect(after.enabled).to be(true)
    end
  end

  # The tick's check passed; the chain was archived (retired) before the
  # firing's own look: the firing says "archived", as the check would.
  it "fails a chain firing whose end was archived after the check as archived, not gone" do
    Dir.mktmpdir("schedules-chain-archived") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::CHAIN)
      Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
      allow(Samagotchi::SessionContinue).to receive(:run)

      outcome = schedules.send(:fire_chain, entry, Samagotchi::SessionChain::Links.new(state_dir: dir))

      expect([outcome.status, outcome.detail]).to eq(%w[failed archived])
      expect(Samagotchi::SessionContinue).not_to have_received(:run)
    end
  end

  it "keys each chain entry whose target doesn't resolve on its own, not on a shared nil" do
    Dir.mktmpdir("schedules-chain-key") do |root|
      dir = File.join(root, "sessions")
      schedules = store(dir)
      first = schedules.add(target: session(dir).id, prompt: "A", recurrence: every("1m"), mode: described_class::CHAIN)
      second = schedules.add(target: session(dir).id, prompt: "B", recurrence: every("1m"), mode: described_class::CHAIN)
      [first, second].each do |entry|
        FileUtils.rm_f(Samagotchi::Session.session_file(entry.anchor, state_dir: dir))
        FileUtils.rm_rf(Samagotchi::Session.session_dir(entry.anchor, state_dir: dir))
      end
      links = Samagotchi::SessionChain::Links.new(state_dir: dir)

      keys = [first, second].map { |entry| schedules.send(:chain_key, links, entry) }

      expect(keys).to eq(["unresolved:#{first.id}", "unresolved:#{second.id}"])
    end
  end

  it "queues a same-mode turn into the chain's latest link after a human continue" do
    Dir.mktmpdir("schedules-same-continue") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Check the queue", recurrence: every("1m"), mode: described_class::SAME)
      # A person continues the session: the anchor is archived, the schedule's
      # head is still it. Reading the anchor literally would fail "archived"
      # every tick and disable the schedule after three of them.
      link = Samagotchi::SessionContinue.run(anchor, prompt: "carried on by hand", state_dir: dir)
      set_idle(dir, link.id) # the link is still marked running from its spawn
      delivered = []
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, prompt:, **kwargs|
        delivered << { id: id, prompt: prompt, delivery: kwargs[:delivery] }
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file, ack: { "enqueued_id" => "scheduled-turn" })
      end

      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect([outcome.status, outcome.detail]).to eq(["pending", "queued a turn"])
      expect(delivered).to eq([{ id: link.id, prompt: "Check the queue", delivery: Samagotchi::Delivery::QUEUE }])
      expect(archived?(dir, anchor)).to be(true)
    end
  end

  it "keeps a same-mode entry's head at the link it last fired into" do
    Dir.mktmpdir("schedules-same-head") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: described_class::SAME)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, _prompt, **_kwargs|
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file, ack: { "enqueued_id" => "scheduled-turn" })
      end

      schedules.tick(now: Time.now + 120)
      expect(schedules.lookup(entry.id).head).to eq(anchor)
      complete_pending(dir, schedules, entry.id)

      link = Samagotchi::SessionContinue.run(anchor, prompt: "by hand", state_dir: dir)
      set_idle(dir, link.id)
      expect(schedules.run_now(entry.id).status).to eq("pending")
      stored = schedules.lookup(entry.id)
      expect([stored.anchor, stored.head]).to eq([anchor, link.id])

      # The head, not the archived anchor, is what the next tick resolves from.
      complete_pending(dir, schedules, entry.id)
      set_idle(dir, link.id)
      expect(schedules.tick(now: Time.now + 240).outcomes.first.status).to eq("pending")
    end
  end

  # A person's continue of the chain's end (chi send --new --continues, web continue →)
  # writes its intent and archives the link before its successor is saved: a
  # tick in that moment sees an archived end. It is "not now", not a retired
  # chain.
  describe "a continue of the target in flight" do
    let(:successor) { "7b2d41aa-0000-4000-8000-000000000000" }
    let(:locks) { [] }

    after { locks.each(&:close) }

    def continuing(dir, id, successor_id, hold: true)
      folder = Samagotchi::Session.session_dir(id, state_dir: dir)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, Samagotchi::ContinueIntent::FILE), JSON.generate(successor_id: successor_id))
      return unless hold

      path = File.join(folder, Samagotchi::ContinueIntent::LOCK)
      lock = File.open(path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose, closed after
      lock.flock(File::LOCK_EX)
      locks << lock
    end

    %w[chain same].each do |mode|
      it "skips a #{mode} entry, moving no failure and firing nothing" do
        Dir.mktmpdir("schedules-continuing") do |root|
          dir = File.join(root, "sessions")
          allow(Process).to receive(:spawn).and_return(12_345)
          allow(Samagotchi::SessionManager).to receive(:deliver_turn)
          anchor = session(dir).id
          schedules = store(dir)
          entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: mode)
          Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
          continuing(dir, anchor, successor)

          outcome = schedules.tick(now: Time.now + 60).outcomes.first

          expect([outcome.status, outcome.detail]).to eq(["skipped", "being continued as 7b2d41aa; retry at the next tick"])
          expect(schedules.lookup(entry.id)).to have_attributes(failures: 0, skips: 1, head: anchor, next_due: entry.next_due)
          expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).map(&:id)).to eq([anchor])
          expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
          expect(Process).not_to have_received(:spawn)
        end
      end
    end

    it "fails as archived when the intent is stale (no continue holds its lock)" do
      Dir.mktmpdir("schedules-continuing-stale") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::SAME)
        Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
        continuing(dir, anchor, successor, hold: false)

        outcome = schedules.tick(now: Time.now + 60).outcomes.first

        expect([outcome.status, outcome.detail]).to eq(%w[failed archived])
        expect(schedules.lookup(entry.id).failures).to eq(1)
      end
    end

    it "fires at the successor once it is saved, the intent still in place" do
      Dir.mktmpdir("schedules-continuing-saved") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::SAME)
        Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
        saved = session(dir, continues: anchor).id
        continuing(dir, anchor, saved)
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
          Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                        ack: { "enqueued_id" => "scheduled-turn" })
        )

        outcome = schedules.tick(now: Time.now + 60).outcomes.first

        expect(outcome).to have_attributes(status: "pending", detail: "queued a turn")
        expect(Samagotchi::SessionManager).to have_received(:deliver_turn).with(saved, hash_including(prompt: "Audit"))
        expect(schedules.lookup(entry.id)).to have_attributes(head: saved, failures: 0)
      end
    end

    # The tick's listing saw a live target; the continue archived it before
    # the firing's own look at the files.
    it "skips a same-mode firing whose target was archived for a continue after the check" do
      Dir.mktmpdir("schedules-continuing-fire") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::SAME)
        links = Samagotchi::SessionChain::Links.new(state_dir: dir)
        expect(links.archived?(anchor)).to be(false)
        Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
        continuing(dir, anchor, successor)
        allow(Samagotchi::SessionManager).to receive(:deliver_turn)

        outcome = schedules.send(:fire_same, entry, links)

        expect([outcome.status, outcome.detail]).to eq(["skipped", "being continued as 7b2d41aa; retry at the next tick"])
        expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
      end
    end

    # The tick's listing saw a live target; a continue ended (its successor
    # saved, its intent gone) before the firing's own look: the stale
    # listing says "archived", a fresh walk says where the chain went.
    it "fires a same-mode entry into the successor of a continue that ended after the tick's listing" do
      Dir.mktmpdir("schedules-continued-fire") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::SAME)
        links = Samagotchi::SessionChain::Links.new(state_dir: dir)
        expect(links.latest(anchor)).to eq(anchor)
        Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
        saved = session(dir, continues: anchor).id
        allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
          Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                        ack: { "enqueued_id" => "scheduled-turn" })
        )

        outcome = schedules.send(:fire_same, entry, links)

        expect(outcome).to have_attributes(status: "pending", detail: "queued a turn")
        expect(Samagotchi::SessionManager).to have_received(:deliver_turn).with(saved, hash_including(prompt: "Audit"))
        expect(outcome.entry.head).to eq(saved)
      end
    end

    it "still fails a same-mode firing as archived when a fresh walk finds no successor either" do
      Dir.mktmpdir("schedules-retired-fire") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: described_class::SAME)
        links = Samagotchi::SessionChain::Links.new(state_dir: dir)
        expect(links.latest(anchor)).to eq(anchor)
        Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
        allow(Samagotchi::SessionManager).to receive(:deliver_turn)

        outcome = schedules.send(:fire_same, entry, links)

        expect([outcome.status, outcome.detail]).to eq(%w[failed archived])
        expect(Samagotchi::SessionManager).not_to have_received(:deliver_turn)
      end
    end
  end

  it "records a run-now refusal, so a schedule that can never fire is disabled" do
    Dir.mktmpdir("schedules-run-now-record") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Wake", recurrence: every("1m"), mode: described_class::SAME)
      inbox = Samagotchi::Session.session_dir(anchor, state_dir: dir)
      Samagotchi::SessionInbox.write_input(inbox, prompt: "a turn is queued")

      # Busy is a skip, counted the way a tick counts one, with the clock left
      # where it was: run-now is not a scheduled occurrence, so there is no
      # due_was to put back.
      expect(schedules.run_now(entry.id).status).to eq("skipped")
      expect(schedules.lookup(entry.id).skips).to eq(1)
      Samagotchi::SessionInbox.find_new_input_files(inbox).each { |file| File.delete(file) }

      Samagotchi::ArchiveStore.archive(anchor, state_dir: dir)
      3.times do
        outcome = schedules.run_now(entry.id)
        expect([outcome.status, outcome.detail]).to eq(%w[failed archived])
      end

      after = schedules.lookup(entry.id)
      expect([after.failures, after.skips, after.enabled, after.last_result]).to eq([3, 1, false, "archived"])
      expect(after.next_due).to eq(entry.next_due)
      expect(schedules.entries).to be_empty
    end
  end

  it "uses a weekday interval for a run-now pending turn's expiry window" do
    Dir.mktmpdir("schedules-run-now-weekday-window") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      now = Time.local(2026, 11, 10, 12)
      schedules = store(dir, now: now)
      entry = schedules.add(target: anchor, prompt: "Check",
                            recurrence: described_class.recurrence(weekday: now.to_date.cwday, time: "12:00"),
                            mode: described_class::SAME)
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => "scheduled-turn" })
      )

      expect(schedules.run_now(entry.id).status).to eq("pending")
      outcome = schedules.tick(now: now + described_class::PENDING_MIN_SECONDS + 1).outcomes.first

      expect(outcome).to have_attributes(status: "pending")
    end
  end

  it "does not fire an `every 30m` schedule at every tick" do
    Dir.mktmpdir("schedules-every") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Audit", recurrence: every("30m"))
      now = Time.now
      firings = 0
      8.times do |step|
        outcomes = schedules.tick(now: now + (step * 300)).outcomes
        firings += outcomes.count { |outcome| outcome.status == "pending" }
        complete_pending(dir, schedules, outcomes.find { |outcome| outcome.status == "pending" }&.id)
      end
      expect(firings).to eq(1)
    end
  end

  it "disables a `date` schedule once it has fired: there is no next occurrence" do
    Dir.mktmpdir("schedules-date") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "One thing", recurrence: described_class.recurrence(date: "2026-01-01T09:00"))

      expect(schedules.tick.outcomes.first.status).to eq("pending")

      stored = schedules.lookup(entry.id)
      expect([stored.enabled, stored.next_due]).to eq([false, nil])
      expect(schedules.entries).to be_empty
      expect(schedules.entries(include_disabled: true).map(&:last_result))
        .to eq(["new link #{stored.head[0, 8]}"])
    end
  end

  it "finds an entry by title for enable, disable and cancel" do
    Dir.mktmpdir("schedules-title") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", title: "Audit", recurrence: every("1h"))

      expect(schedules.disable("audit").id).to eq(entry.id)
      expect(schedules.entries).to be_empty
      expect(schedules.entries(include_disabled: true).first.enabled).to be(false)
      schedules.enable("Audit")
      expect(schedules.lookup("Audit").enabled).to be(true)
      expect(schedules.cancel("Audit").id).to eq(entry.id)
      expect(schedules.entries).to be_empty
    end
  end

  it "asks a live worker what it is busy with, and skips on each of those signals" do
    [["chain", { turn_running: true }, "a turn is running in it"],
     ["chain", { input_pending: true }, "a prompt is queued for it"],
     ["chain", { awaiting_continue: true }, "its step-limit question waits for an answer"],
     ["chain", { open_streams: 1 }, "a terminal or a web tab is open on it"],
     ["same", { turn_running: true }, "a turn is running in it"],
     ["same", { input_pending: true }, "a prompt is queued for it"],
     ["same", { awaiting_continue: true }, "its step-limit question waits for an answer"]].each do |mode, snapshot, reason|
      Dir.mktmpdir("schedules-live-worker") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        session_dir = Samagotchi::Session.session_dir(anchor, state_dir: dir)
        Samagotchi::WorkerSidecar.new(port: 9, session_id: anchor, pid: Process.pid,
                                      features: [Samagotchi::WorkerLink::ACTIVITY_FEATURE]).write(session_dir)
        lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
        allow(Samagotchi::BridgeClient).to receive(:new).and_return(double("client", get: [200, snapshot]))

        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"), mode: mode)
        outcome = schedules.tick(now: Time.now + 120).outcomes.first

        expect([outcome.status, outcome.detail]).to eq(["skipped", reason])
        expect(schedules.lookup(entry.id).skips).to eq(1)
        lock.release
      end
    end
  end

  it "queues a turn in same mode even when a tab is open on the worker" do
    Dir.mktmpdir("schedules-live-same") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      session_dir = Samagotchi::Session.session_dir(anchor, state_dir: dir)
      Samagotchi::WorkerSidecar.new(port: 9, session_id: anchor, pid: Process.pid,
                                    features: [Samagotchi::WorkerLink::ACTIVITY_FEATURE]).write(session_dir)
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Samagotchi::BridgeClient).to receive(:new).and_return(double("client", get: [200, { open_streams: 2 }]))
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |_id, prompt:, **_kwargs|
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file, ack: { "enqueued_id" => "scheduled-turn" })
      end

      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: described_class::SAME)
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect([outcome.status, outcome.detail]).to eq(["pending", "queued a turn"])
      lock.release
    end
  end

  it "skips when the live worker does not answer at all" do
    Dir.mktmpdir("schedules-live-dead") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      session_dir = Samagotchi::Session.session_dir(anchor, state_dir: dir)
      Samagotchi::WorkerSidecar.new(port: 9, session_id: anchor, pid: Process.pid,
                                    features: [Samagotchi::WorkerLink::ACTIVITY_FEATURE]).write(session_dir)
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Samagotchi::BridgeClient).to receive(:new).and_return(double("client", get: [nil, nil]))

      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect([outcome.status, outcome.detail]).to eq(["skipped", "its worker is not answering"])
      lock.release
    end
  end

  it "skips a chain firing whose live worker has no /activity route" do
    Dir.mktmpdir("schedules-old-worker") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      session_dir = Samagotchi::Session.session_dir(anchor, state_dir: dir)
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      Samagotchi::WorkerSidecar.new(port: 9, session_id: anchor, pid: Process.pid, features: ["restart"]).write(session_dir)

      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect(outcome.status).to eq("skipped")
      expect(outcome.detail).to include("too old to ask")
      expect(schedules.lookup(entry.id).skips).to eq(1)
      lock.release
    end
  end

  it "answers a tick that finds the lock held with nothing due" do
    Dir.mktmpdir("schedules-locked-tick") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      held = File.open(schedules.lock_path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose, closed at the end
      held.flock(File::LOCK_EX)
      tick = schedules.tick(now: Time.now + 120)
      expect([tick.locked, tick.outcomes]).to eq([true, []])
      held.flock(File::LOCK_UN)
      held.close
      expect(schedules.lookup(entry.id).skips).to eq(0)
    end
  end

  it "records a failure when the firing itself blows up, and puts the clock back" do
    Dir.mktmpdir("schedules-firing") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_raise(Errno::ENOSPC)
      allow(Samagotchi::Log).to receive(:warn)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1m"))
      outcome = schedules.tick(now: Time.now + 120).outcomes.first
      expect(outcome.status).to eq("failed")
      expect(outcome.detail).to include("Errno::ENOSPC")
      after = schedules.lookup(entry.id)
      expect(after.firing_since).to be_nil
      expect(after.failures).to eq(1)
      # The occurrence this tick tried comes back: it failed, it was not late.
      expect(Time.iso8601(after.next_due)).to eq(Time.iso8601(after.due_was))
      expect(Time.iso8601(after.next_due)).to eq(Time.iso8601(entry.next_due))
    end
  end

  it "marks an entry firing before the action, then records an interrupted firing without replaying it" do
    [
      ["every", every("1m")],
      ["weekday", described_class.recurrence(weekday: 1, time: "09:00")],
      ["date", described_class.recurrence(date: "2026-01-01T09:00")]
    ].each do |kind, recurrence|
      Dir.mktmpdir("schedules-killed") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Audit", recurrence: recurrence)
        now = Time.iso8601(entry.next_due) + 60
        # Interrupt is not a StandardError: `fire` does not rescue it, so the
        # tick dies between the advance and the action.
        allow(Samagotchi::SessionContinue).to receive(:run).and_raise(Interrupt)

        expect { schedules.tick(now: now) }.to raise_error(Interrupt)

        after = schedules.lookup(entry.id)
        expect(after.firing_since).to match(/\d{4}-\d{2}-\d{2}T/)
        expect(after.due_was).to eq(entry.next_due)
        expect(schedules.entries).to be_empty if kind == "date" # a one-off is spent
        # The tick that died already moved the clock: a tick at the same
        # instant finds nothing due, and nothing was archived.
        expect(schedules.tick(now: now).outcomes).to be_empty
        expect(archived?(dir, anchor)).to be(false)

        outcome = schedules.tick(now: now + described_class::FIRING_TIMEOUT).outcomes.first
        expect([outcome.status, outcome.detail]).to eq(%w[failed interrupted])
        after = schedules.lookup(entry.id)
        expect([after.firing_since, after.failures, after.last_result]).to eq([nil, 1, "interrupted"])
        expect(after.enabled).to eq(kind != "date")
        expect(schedules.entries).to be_empty if kind == "date"
      end
    end
  end

  it "drops a firing result that arrives after the reaper has recorded the interruption" do
    Dir.mktmpdir("schedules-stale-record") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      now = Time.utc(2026, 11, 10, 12)
      schedules = store(dir, now: now)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      due = Time.iso8601(entry.next_due) + 1
      started = Queue.new
      release = Queue.new
      allow(schedules).to receive(:fire) do |reserved, _index|
        started << true
        release.pop
        described_class::Outcome.new(id: reserved.id, title: reserved.title, status: "failed",
                                     detail: "late result", entry: reserved)
      end
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      firing = Thread.new { schedules.tick(now: due) }
      started.pop
      reaped = schedules.tick(now: due + described_class::FIRING_TIMEOUT).outcomes.first
      release << true
      firing.value

      expect(reaped).to have_attributes(status: "failed", detail: "interrupted")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, last_result: "interrupted")
      expect(Samagotchi::Log).to have_received(:warn).with(
        :worker, "schedule_record_stale", hash_including(id: entry.id)
      )
    ensure
      release << true if firing&.alive?
      firing&.join
    end
  end

  it "keeps the occurrence when the firing is refused, and fires it at the next tick" do
    Dir.mktmpdir("schedules-race-skip") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      child = session(dir, parent: anchor, delegate: true, status: Samagotchi::Session::STATUS_RUNNING)
      # A terminal owns the running delegate: the continue of the anchor
      # refuses it (open_children) rather than move it under a new link.
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(child.id, state_dir: dir), kind: "tui")
      monday = Time.local(2026, 11, 9, 9, 0)
      schedules = store(dir, now: monday - 60)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: described_class.recurrence(weekday: 1, time: "09:00"))
      expect(Time.iso8601(entry.next_due)).to eq(monday)

      outcome = schedules.tick(now: monday).outcomes.first
      expect(outcome.status).to eq("skipped")
      expect(outcome.detail).to include(child.id[0, 8])

      after = schedules.lookup(entry.id)
      expect([after.skips, after.enabled, Time.iso8601(after.next_due)]).to eq([1, true, monday])

      # The terminal on the delegate goes; the next tick fires the Monday run
      # the skipped one tried.
      lock.release
      fired = schedules.tick(now: monday + 120).outcomes.first
      expect(fired.status).to eq("pending")
      expect(Time.iso8601(schedules.lookup(entry.id).next_due)).to eq(Time.local(2026, 11, 16, 9, 0))
    end
  end

  it "keeps an accepted schedule turn pending until that turn completes" do
    Dir.mktmpdir("schedules-pending-success") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1

      started = schedules.tick(now: started_at).outcomes.first
      expect(started).to have_attributes(status: "pending", detail: "queued a turn")
      expect(schedules.lookup(entry.id)).to have_attributes(
        pending_session_id: anchor, pending_turn_id: turn_id, failures: 0, skips: 0
      )

      saved = Samagotchi::Session.load(anchor, state_dir: dir)
      saved.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: (started_at + 1).iso8601,
                                                 origin: "schedule", enqueued_id: turn_id)
      saved.save(state_dir: dir)
      resolved = schedules.tick(now: started_at + 2).outcomes.first

      expect(resolved).to have_attributes(status: "fired", detail: "turn completed")
      expect(schedules.lookup(entry.id)).to have_attributes(
        pending_session_id: nil, pending_turn_id: nil, failures: 0, skips: 0, last_result: "turn completed"
      )
    end
  end

  it "counts failed and canceled schedule turns as failures with their reasons" do
    %w[failed canceled].each do |turn_outcome|
      Dir.mktmpdir("schedules-pending-#{turn_outcome}") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        schedules = store(dir)
        entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1d"), mode: "same")
        turn_id = "scheduled-turn"
        deliveries = 0
        allow(Samagotchi::SessionManager).to receive(:deliver_turn) do
          deliveries += 1
          Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                        ack: { "enqueued_id" => turn_id })
        end
        started_at = Time.iso8601(entry.next_due) + 1
        expect(schedules.tick(now: started_at).outcomes.first.status).to eq("pending")

        saved = Samagotchi::Session.load(anchor, state_dir: dir)
        saved.last_turn = Samagotchi::LastTurn.new(outcome: turn_outcome, ended_at: (started_at + 1).iso8601,
                                                   enqueued_id: turn_id,
                                                   error_kind: (turn_outcome == "failed" ? "server" : nil),
                                                   cancel_reason: (turn_outcome == "canceled" ? "user" : nil))
        saved.save(state_dir: dir)
        resolved = schedules.tick(now: started_at + 2).outcomes.first

        expect(resolved).to have_attributes(status: "failed")
        expect(resolved.detail).to include(turn_outcome)
        expect(resolved.detail).to include(turn_outcome == "failed" ? "server" : "user")
        expect(schedules.lookup(entry.id)).to have_attributes(
          pending_session_id: nil, pending_turn_id: nil, failures: 1,
          next_due: (started_at + 86_400).iso8601
        )
        expect(schedules.tick(now: started_at + 3).outcomes).to be_empty
        expect(deliveries).to eq(1)
      end
    end
  end

  it "does not re-enable or replay a date schedule when its accepted turn fails" do
    Dir.mktmpdir("schedules-pending-date-failure") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: described_class.recurrence(date: "2099-01-01T12:00"),
                            mode: "same")
      deliveries = 0
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do
        deliveries += 1
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => "scheduled-turn" })
      end
      started_at = Time.iso8601(entry.next_due) + 1
      expect(schedules.tick(now: started_at).outcomes.first.status).to eq("pending")

      saved = Samagotchi::Session.load(anchor, state_dir: dir)
      saved.last_turn = Samagotchi::LastTurn.new(outcome: "failed", ended_at: (started_at + 1).iso8601,
                                                 enqueued_id: "scheduled-turn")
      saved.save(state_dir: dir)
      expect(schedules.tick(now: started_at + 2).outcomes.first.status).to eq("failed")

      expect(schedules.lookup(entry.id)).to have_attributes(
        enabled: false, next_due: nil, failures: 1, pending_turn_id: nil
      )
      expect(schedules.tick(now: started_at + 3).outcomes).to be_empty
      expect(deliveries).to eq(1)
    end
  end

  it "resolves a pending turn from its own reply after a newer turn has run" do
    Dir.mktmpdir("schedules-pending-own-turn") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1
      schedules.tick(now: started_at)
      Samagotchi::SessionInbox.write_output(
        Samagotchi::Session.session_dir(anchor, state_dir: dir), "done", enqueued_id: turn_id
      )

      saved = Samagotchi::Session.load(anchor, state_dir: dir)
      saved.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: (started_at + 2).iso8601,
                                                 enqueued_id: "later-turn")
      saved.save(state_dir: dir)

      resolved = schedules.tick(now: started_at + 3).outcomes.first

      expect(resolved).to have_attributes(status: "fired", detail: "turn completed")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 0, pending_turn_id: nil)
    end
  end

  it "resolves its own completed turn before a later turn's pending question" do
    Dir.mktmpdir("schedules-pending-later-question") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1
      schedules.tick(now: started_at)
      Samagotchi::SessionInbox.write_output(
        Samagotchi::Session.session_dir(anchor, state_dir: dir), "done", enqueued_id: turn_id
      )

      saved = Samagotchi::Session.load(anchor, state_dir: dir)
      saved.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: (started_at + 2).iso8601,
                                                 enqueued_id: "later-turn")
      saved.pending_question = Samagotchi::PendingQuestion.new(id: "question", kind: "approval",
                                                               created_at: (started_at + 3).iso8601)
      saved.save(state_dir: dir)

      resolved = schedules.tick(now: started_at + 4).outcomes.first

      expect(resolved).to have_attributes(status: "fired", detail: "turn completed")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 0, pending_turn_id: nil)
    end
  end

  it "fails a pending firing when its session is gone" do
    Dir.mktmpdir("schedules-pending-session-gone") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1
      schedules.tick(now: started_at)
      File.delete(File.join(dir, "#{anchor}.json"))

      resolved = schedules.tick(now: started_at + 1).outcomes.first

      expect(resolved).to have_attributes(status: "failed", detail: "session gone")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, pending_turn_id: nil)
    end
  end

  it "fails a pending turn with no known outcome after its bounded hard limit" do
    Dir.mktmpdir("schedules-pending-hard-limit") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1
      schedules.tick(now: started_at)
      limit = started_at + described_class::PENDING_MIN_SECONDS

      expect(schedules.tick(now: limit - 1).outcomes.first.status).to eq("pending")
      resolved = schedules.tick(now: limit).outcomes.first

      expect(resolved).to have_attributes(status: "failed", detail: "no outcome")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, pending_turn_id: nil)
    end
  end

  it "expires a stale pending turn id left by an older ticker" do
    Dir.mktmpdir("schedules-stale-pending-id") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      now = Time.utc(2026, 11, 10, 12)
      schedules = store(dir, now: now)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
      data = JSON.parse(File.read(schedules.path))
      data.fetch("schedules").first.merge!(
        "firing_since" => (now - described_class::PENDING_MIN_SECONDS - 1).iso8601,
        "pending_session_id" => anchor,
        "pending_turn_id" => "stale-ticker-turn"
      )
      File.write(schedules.path, JSON.generate(data))

      outcome = schedules.tick(now: now).outcomes.first

      expect(outcome).to have_attributes(status: "failed", detail: "no outcome")
      expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, pending_turn_id: nil)
    end
  end

  it "expires pending turns with a missing or invalid firing timestamp" do
    [nil, "not-a-time"].each do |firing_since|
      Dir.mktmpdir("schedules-pending-missing-firing-time") do |root|
        dir = File.join(root, "sessions")
        anchor = session(dir).id
        now = Time.utc(2026, 11, 10, 12)
        schedules = store(dir, now: now)
        entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1m"), mode: "same")
        data = JSON.parse(File.read(schedules.path))
        data.fetch("schedules").first.merge!(
          "firing_since" => firing_since,
          "pending_session_id" => anchor,
          "pending_turn_id" => "stale-ticker-turn"
        )
        File.write(schedules.path, JSON.generate(data))

        outcome = schedules.tick(now: now).outcomes.first

        expect(outcome).to have_attributes(status: "failed", detail: "no outcome")
        expect(schedules.lookup(entry.id)).to have_attributes(failures: 1, pending_turn_id: nil)
      end
    end
  end

  it "keeps a schedule turn waiting on a question pending until its hard limit" do
    Dir.mktmpdir("schedules-pending-question") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Check", recurrence: every("1d"), mode: "same")
      turn_id = "scheduled-turn"
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file,
                                                      ack: { "enqueued_id" => turn_id })
      )
      started_at = Time.iso8601(entry.next_due) + 1
      expect(schedules.tick(now: started_at).outcomes.first.status).to eq("pending")

      saved = Samagotchi::Session.load(anchor, state_dir: dir)
      saved.last_turn = Samagotchi::LastTurn.new(outcome: "completed", ended_at: (started_at + 1).iso8601,
                                                 enqueued_id: turn_id)
      saved.pending_question = Samagotchi::PendingQuestion.new(id: "question", kind: "approval",
                                                               created_at: started_at.iso8601)
      saved.save(state_dir: dir)

      waiting = schedules.tick(now: started_at + described_class::FIRING_TIMEOUT + 1).outcomes.first
      expect(waiting).to have_attributes(status: "pending", detail: "turn is waiting for an answer")

      limit = started_at + described_class::PENDING_MAX_SECONDS
      expect(schedules.tick(now: limit - 1).outcomes.first.status).to eq("pending")
      failed = schedules.tick(now: limit).outcomes.first
      expect(failed).to have_attributes(status: "failed", detail: "no outcome")
      expect(schedules.lookup(entry.id)).to have_attributes(
        failures: 1, pending_turn_id: nil, next_due: (started_at + 86_400).iso8601
      )
      expect(schedules.tick(now: limit + 1).outcomes).to be_empty
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn).once
    end
  end
end
