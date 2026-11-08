# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/schedules"
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

  def store(state_dir, now: Time.now)
    described_class.new(state_dir: state_dir, clock: -> { now })
  end

  it "writes every entry under the lock, so nothing is lost" do
    Dir.mktmpdir("schedules-lock") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      held = File.open(File.join(dir, described_class::LOCK), File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held open on purpose, closed at the end
      held.flock(File::LOCK_EX)

      blocked = Thread.new { schedules.add(target: id, prompt: "one", recurrence: every("1h")) }
      sleep 0.2 # sleep-ok: the blocked thread's wait on the lock is the behaviour being tested
      held.flock(File::LOCK_UN)
      schedules.add(target: id, prompt: "two", recurrence: every("2h"))
      blocked.join

      expect(schedules.entries.map(&:prompt)).to eq(%w[one two])
      held.close
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

  it "takes one recurrence kind, and --weekday needs --time" do
    expect { described_class.recurrence }.to raise_error(described_class::Usage, /needs one of/)
    expect { described_class.recurrence(every: "1h", weekday: 1, time: "09:00") }.to raise_error(described_class::Usage, /not more/)
    expect { described_class.recurrence(weekday: 1) }.to raise_error(described_class::Usage, /needs --time/)
    expect { described_class.recurrence(weekday: 9, time: "09:00") }.to raise_error(described_class::Usage, /1 \(Mon\) to 7/)
    expect { described_class.recurrence(every: "1w") }.to raise_error(described_class::Usage, /every must be/)
    expect { described_class.recurrence(date: "2026-13-01") }.to raise_error(described_class::Usage, /date must be/)
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

  it "fires a chain entry once, archiving the previous link and moving the head" do
    Dir.mktmpdir("schedules-chain") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit the queue", recurrence: every("1m"))

      fired = schedules.tick(now: Time.now + 60).outcomes.first
      expect(fired.status).to eq("fired")
      expect(fired.detail).to start_with("new link")

      stored = schedules.lookup(entry.id)
      expect(stored.head).to eq(fired.entry.head)
      expect(archived?(dir, anchor)).to be(true)
      expect(Samagotchi::Session.load(stored.head, state_dir: dir).continues).to eq(anchor)
      expect(stored.failures).to eq(0)
      expect(stored.skips).to eq(0)
      expect(Time.iso8601(stored.next_due)).to be > Time.now
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
      after = schedules.lookup(entry.id)
      expect([after.skips, after.failures, after.enabled]).to eq([0, 0, true])
    end
  end

  it "moves to the next occurrence with catch_up none instead of firing late" do
    Dir.mktmpdir("schedules-catchup") do |root|
      dir = File.join(root, "sessions")
      anchor = session(dir).id
      schedules = store(dir)
      entry = schedules.add(target: anchor, prompt: "Audit", recurrence: every("1h"), catch_up: "none")
      ticked = Time.now + 4200
      tick = schedules.tick(now: ticked)
      expect(tick.outcomes.first.status).to eq("missed")
      after = schedules.lookup(entry.id)
      expect(after.last_result).to eq("missed")
      expect(Time.iso8601(after.next_due)).to be > ticked
      expect(Samagotchi::Session.list(state_dir: dir, include_archived: true).size).to eq(1)
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
      Samagotchi::SessionManager.delete_session(anchor, state_dir: dir)

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
      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      # Three more firings: run_now fires whatever the clock says, so the
      # window is tested against a real chain length.
      3.times do
        set_idle(dir, schedules.lookup(entry.id).head)
        schedules.run_now(entry.id)
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
        schedules.tick(now: Time.now + 120 + (step * 120))
      end

      ids = Samagotchi::Session.list(state_dir: dir, include_archived: true).map(&:id)
      expect(ids).to include(root, middle, schedules.lookup(entry.id).head)
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
      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      # The child's delete is refused (its worker is still there).
      allow(Samagotchi::SessionManager).to receive(:delete_session).and_call_original
      allow(Samagotchi::SessionManager).to receive(:delete_session).with(child.id, state_dir: dir) do
        raise Samagotchi::SessionManager::DeleteRefused.new(child.id, :worker_running)
      end

      set_idle(dir, first)
      outcome = schedules.tick(now: Time.now + 240).outcomes.first
      expect(outcome.status).to eq("fired")

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
      set_idle(dir, first)
      schedules.tick(now: Time.now + 240)
      head = schedules.lookup(entry.id).head

      child = session(dir, parent: first, delegate: true)
      Samagotchi::ArchiveStore.archive(child.id, state_dir: dir)
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(child.id, state_dir: dir), kind: "worker")

      # This firing pushes `first` out of the window: its subtree has a worker,
      # so nothing in it is deleted.
      set_idle(dir, head)
      expect(schedules.tick(now: Time.now + 480).outcomes.first.status).to eq("fired")
      # Nothing in that subtree is deleted while a worker owns part of it.
      expect(archived?(dir, first)).to be(true)
      expect(Samagotchi::Session.exist?(child.id, state_dir: dir)).to be(true)

      lock.release
      set_idle(dir, schedules.lookup(entry.id).head)
      schedules.run_now(entry.id)
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
        schedules.tick(now: Time.now + 120 + (step * 120))
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
      set_idle(dir, first)
      schedules.tick(now: Time.now + 240)
      # `first` is archived now but still inside the window; the next firing
      # pushes it out, and its worker refuses the delete.
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(first, state_dir: dir), kind: "worker")
      set_idle(dir, schedules.lookup(entry.id).head)
      outcome = schedules.tick(now: Time.now + 360).outcomes.first
      expect(outcome.status).to eq("fired")
      after = schedules.lookup(entry.id)
      expect(after.failures).to eq(0)
      expect(archived?(dir, first)).to be(true)
      lock.release
      set_idle(dir, schedules.lookup(entry.id).head)
      fired = schedules.run_now(entry.id)
      expect(fired.status).to eq("fired")
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
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :file, ack: {})
      end
      tick = schedules.tick(now: Time.now + 120)
      expect(tick.outcomes.first.status).to eq("fired")
      expect(delivered[:delivery]).to eq(Samagotchi::Delivery::QUEUE)
      expect(delivered[:client_id]).to eq(Samagotchi::ClientId.schedule(entry.id))
      expect(schedules.lookup(entry.id).last_result).to eq("queued a turn")
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

  it "does not fire an `every 30m` schedule at every tick" do
    Dir.mktmpdir("schedules-every") do |root|
      dir = File.join(root, "sessions")
      allow(Process).to receive(:spawn).and_return(12_345)
      anchor = session(dir).id
      schedules = store(dir)
      schedules.add(target: anchor, prompt: "Audit", recurrence: every("30m"))
      now = Time.now
      firings = 0
      8.times { |step| firings += schedules.tick(now: now + (step * 300)).outcomes.count { |outcome| outcome.status == "fired" } }
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

      expect(schedules.tick.outcomes.first.status).to eq("fired")

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

  it "marks an entry firing before the action, so a tick killed mid-continue cannot fire it again" do
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
      end
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
      expect(fired.status).to eq("fired")
      expect(Time.iso8601(schedules.lookup(entry.id).next_due)).to eq(Time.local(2026, 11, 16, 9, 0))
    end
  end
end
