# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session_retention"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::SessionRetention do
  let(:tmpdir) { Dir.mktmpdir("session-retention-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".apply" do
    it "with any_age deletes every eligible session however new, still keeping live and keep_status ones" do
      mk = ->(**attrs) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true).tap { |x| attrs.each { |k, v| x.public_send("#{k}=", v) }; x.save(state_dir: tmpdir) } }
      fresh = mk.call
      running = mk.call(status: "running")
      live = mk.call
      other = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false).tap { |x| x.save(state_dir: tmpdir) }

      result = described_class.apply(state_dir: tmpdir, days: 0, max_count: 0, keep_status: ["running"], test_only: true,
                                     any_age: true, alive_check: ->(id) { id == live.id })

      expect(result[:deleted]).to eq([fresh.id])
      expect(result[:kept]).to contain_exactly(running.id, live.id)
      expect(File.exist?(File.join(tmpdir, "#{other.id}.json"))).to be true
    end

    it "removes a pruned session's plugin state (plugins/<bundle>/sessions/<id>.json)" do
      s = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true)
      s.save(state_dir: tmpdir)
      state = File.join(Samagotchi::Paths.state_dir, "plugins", "check-in", "sessions", "#{s.id}.json")
      FileUtils.mkdir_p(File.dirname(state))
      File.write(state, "{}")

      result = described_class.apply(state_dir: tmpdir, days: 0, max_count: 0, test_only: true, any_age: true)

      expect(result[:deleted]).to eq([s.id])
      expect(File.exist?(state)).to be false
    ensure
      FileUtils.rm_rf(File.join(Samagotchi::Paths.state_dir, "plugins"))
    end

    it "deletes sessions older than days" do
      s_old = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s_old.save(state_dir: tmpdir)
      # fake old updated_at
      old_time = (Time.now - 20 * 86_400).iso8601(3)
      path_old = File.join(tmpdir, "#{s_old.id}.json")
      data = JSON.parse(File.read(path_old))
      data["updated_at"] = old_time
      data["created_at"] = old_time
      File.write(path_old, JSON.generate(data))

      s_new = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s_new.save(state_dir: tmpdir)

      result = described_class.apply(state_dir: tmpdir, days: 14, max_count: 500, dry_run: false)
      expect(result[:deleted]).to include(s_old.id)
      expect(result[:kept]).to include(s_new.id)
      expect(File.exist?(path_old)).to be false
      expect(File.exist?(File.join(tmpdir, "#{s_new.id}.json"))).to be true
    end

    def save_aged(status:, days_old: 20)
      s = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.status = status
      s.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - days_old * 86_400).iso8601(3)
      data["created_at"] = data["updated_at"]
      File.write(path, JSON.generate(data))
      [s, path]
    end

    # status is turn state; a live owner is what protects a session in use.
    it "prunes an old session left 'running' by a dead worker" do
      s_old, path_old = save_aged(status: Samagotchi::Session::STATUS_RUNNING)

      result = described_class.apply(state_dir: tmpdir, days: 14, max_count: 500)
      expect(result[:deleted]).to include(s_old.id)
      expect(File.exist?(path_old)).to be false
    end

    it "keeps an old session with a live owner" do
      s_old, path_old = save_aged(status: Samagotchi::Session::STATUS_IDLE)

      result = described_class.apply(state_dir: tmpdir, days: 14, max_count: 500, alive_check: ->(id) { id == s_old.id })
      expect(result[:kept]).to include(s_old.id)
      expect(File.exist?(path_old)).to be true
    end

    it "still honors an explicit keep_status" do
      s_old, = save_aged(status: Samagotchi::Session::STATUS_RUNNING)

      result = described_class.apply(state_dir: tmpdir, days: 14, max_count: 500, keep_status: ["running"])
      expect(result[:kept]).to include(s_old.id)
    end

    it "respects max_count overflow (deletes beyond limit)" do
      3.times do
        s = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        s.save(state_dir: tmpdir)
        sleep(0.01)
      end
      result = described_class.apply(state_dir: tmpdir, days: 0, max_count: 2)
      expect(result[:deleted].size).to eq(1)
      expect(result[:kept].size).to eq(2)
    end

    it "supports dry_run without deleting" do
      s = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{s.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - 20 * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
      result = described_class.apply(state_dir: tmpdir, days: 14, dry_run: true)
      expect(result[:deleted]).to include(s.id)
      expect(File.exist?(path)).to be true
    end

    it "deletes a session left empty whatever its age, also when retaining forever" do
      empty = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      empty.save(state_dir: tmpdir)
      used = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      used.save(state_dir: tmpdir)

      result = described_class.apply(state_dir: tmpdir, days: 0, max_count: 0, empty_check: ->(id) { id == empty.id })

      expect(result[:deleted]).to eq([empty.id])
      expect(result[:kept]).to eq([used.id])
    end

    it "keeps a session left empty that a live owner has" do
      empty = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      empty.save(state_dir: tmpdir)

      result = described_class.apply(state_dir: tmpdir, empty_check: ->(_) { true }, alive_check: ->(_) { true })

      expect(result[:kept]).to eq([empty.id])
    end

    it "only deletes when json present (skips orphan dirs)" do
      s = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(File.join(tmpdir, "orphan-dir"))
      described_class.apply(state_dir: tmpdir, days: 0, max_count: 0)
      # orphan dir should not be counted as deleted/skipped as it's not a session
      expect(Dir.exist?(File.join(tmpdir, "orphan-dir"))).to be true
    end

    it "filters test_only" do
      s_test = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: true)
      s_test.save(state_dir: tmpdir)
      s_real = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp", test_run: false)
      s_real.save(state_dir: tmpdir)
      # make both old
      [s_test, s_real].each do |s|
        p = File.join(tmpdir, "#{s.id}.json")
        d = JSON.parse(File.read(p))
        d["updated_at"] = (Time.now - 20 * 86_400).iso8601(3)
        File.write(p, JSON.generate(d))
      end
      result = described_class.apply(state_dir: tmpdir, days: 14, test_only: true)
      expect(result[:deleted]).to include(s_test.id)
      expect(result[:deleted]).not_to include(s_real.id)
    end
  end

  describe ".prune and sessions left empty" do
    let(:model) { Samagotchi::ModelProfile.required_model_name(nil) }
    let(:hour_ago) { Time.now - described_class::EMPTY_GRACE_SECONDS - 60 }

    def saved(age: hour_ago, &block)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: "/tmp")
      block&.call(session)
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      File.utime(age, age, path)
      session
    end

    def orphan(name, files: %w[owner.lock], age: hour_ago)
      dir = File.join(tmpdir, name)
      FileUtils.mkdir_p(dir)
      files.each do |file|
        FileUtils.mkdir_p(File.dirname(File.join(dir, file)))
        File.write(File.join(dir, file), "")
      end
      File.utime(age, age, dir)
      dir
    end

    it "deletes an empty session an hour old, keeps a fresh one and one with a conversation" do
      old_empty = saved
      fresh_empty = saved(age: Time.now)
      used = saved { |s| s.messages << { role: "user", content: "hi" } }

      result = described_class.prune(state_dir: tmpdir)

      expect(result[:deleted]).to eq([old_empty.id])
      expect(result[:kept]).to contain_exactly(fresh_empty.id, used.id)
    end

    it "keeps them all with session.keep_empty" do
      allow(Samagotchi::SessionManager).to receive(:discard_empty?).and_return(false)
      old_empty = saved
      dir = orphan("0000-orphan")

      result = described_class.prune(state_dir: tmpdir)

      expect(result[:kept]).to eq([old_empty.id])
      expect(Dir.exist?(dir)).to be(true)
    end

    it "removes an old orphan directory with only the skeleton, not one with input or a fresh one" do
      skeleton = orphan("0000-skeleton", files: %w[owner.lock pid])
      with_input = orphan("0000-input", files: %w[input/1.json])
      fresh = orphan("0000-fresh", age: Time.now)

      result = described_class.prune(state_dir: tmpdir, dry_run: true)
      expect(result[:deleted]).to eq(["0000-skeleton"])
      expect(Dir.exist?(skeleton)).to be(true)

      described_class.prune(state_dir: tmpdir)
      expect(Dir.exist?(skeleton)).to be(false)
      expect(Dir.exist?(with_input)).to be(true)
      expect(Dir.exist?(fresh)).to be(true)
    end

    it "deletes a leftover scratch session at once, keeping one its REPL still owns" do
      scratch = lambda do |s|
        s.messages << { role: "user", content: "hi" }
        s.scratch = true
      end
      leftover = saved(age: Time.now, &scratch)
      running = saved(age: Time.now, &scratch)
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(running.id, state_dir: tmpdir), kind: "tui")

      # keep_status running doesn't save a leftover: nobody runs it.
      Samagotchi::Session.load(leftover.id, state_dir: tmpdir).tap { |s| s.status = Samagotchi::Session::STATUS_RUNNING }.save(state_dir: tmpdir)
      result = described_class.prune(state_dir: tmpdir, keep_status: "running")

      expect(result[:deleted]).to eq([leftover.id])
      expect(File.exist?(File.join(tmpdir, "#{leftover.id}.json"))).to be(false)
      expect(Dir.exist?(File.join(tmpdir, leftover.id))).to be(false)
      expect(File.exist?(File.join(tmpdir, "#{running.id}.json"))).to be(true)
    ensure
      lock&.release
    end
  end

  describe ".prune with the default keep_status" do
    # status is turn state: a "running" left by a crashed worker protects
    # nothing; the live owner (worker or REPL lock) is what keeps a session.
    def aged(status:, days_old: 20)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages << { role: "user", content: "hi" }
      session.status = status
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = data["created_at"] = (Time.now - days_old * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
      session
    end

    def session_dir(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)

    it "keeps no status by default" do
      expect(Samagotchi::Config.get("session.keep_status").to_s).to eq("")
      expect(described_class::DEFAULT_KEEP_STATUS).to eq([])
    end

    it "prunes an old session left running by a dead worker, and keeps old ones a worker or a REPL still owns" do
      crashed = aged(status: Samagotchi::Session::STATUS_RUNNING)
      # The crashed worker's lock file is left behind, no longer held.
      Samagotchi::OwnerLock.acquire(session_dir(crashed), kind: "worker").release
      worker_running = aged(status: Samagotchi::Session::STATUS_RUNNING)
      worker_idle = aged(status: Samagotchi::Session::STATUS_IDLE)
      repl = aged(status: Samagotchi::Session::STATUS_IDLE)
      locks = [
        Samagotchi::OwnerLock.acquire(session_dir(worker_running), kind: "worker"),
        Samagotchi::OwnerLock.acquire(session_dir(worker_idle), kind: "worker"),
        Samagotchi::OwnerLock.acquire(session_dir(repl), kind: "tui")
      ]

      result = described_class.prune(state_dir: tmpdir)

      expect(result[:deleted]).to eq([crashed.id])
      expect(File.exist?(File.join(tmpdir, "#{crashed.id}.json"))).to be(false)
      expect(result[:kept]).to contain_exactly(worker_running.id, worker_idle.id, repl.id)
      [worker_running, worker_idle, repl].each do |s|
        expect(File.exist?(File.join(tmpdir, "#{s.id}.json"))).to be(true)
      end
    ensure
      locks&.each(&:release)
    end

    it "keeps an owned session past the count limit too" do
      owned = aged(status: Samagotchi::Session::STATUS_RUNNING, days_old: 1)
      newer = aged(status: Samagotchi::Session::STATUS_IDLE, days_old: 0)
      lock = Samagotchi::OwnerLock.acquire(session_dir(owned), kind: "worker")

      result = described_class.prune(state_dir: tmpdir, days: 0, max_count: 1)

      expect(result[:kept]).to contain_exactly(owned.id, newer.id)
      expect(result[:deleted]).to be_empty
    ensure
      lock&.release
    end

    # A session deleted whatever its place (scratch here) takes no --keep
    # slot: --keep 1 keeps the newest session that would otherwise stay.
    it "keeps the newest real session with --keep 1 when the newest one is a scratch session" do
      older = [4, 3, 2].map { |days| aged(status: Samagotchi::Session::STATUS_IDLE, days_old: days) }
      newest_real = aged(status: Samagotchi::Session::STATUS_IDLE, days_old: 1)
      scratch = aged(status: Samagotchi::Session::STATUS_IDLE, days_old: 0)
      path = File.join(tmpdir, "#{scratch.id}.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("scratch" => true)))

      result = described_class.prune(state_dir: tmpdir, days: 0, max_count: 1)

      expect(result[:kept]).to eq([newest_real.id])
      expect(result[:deleted]).to contain_exactly(scratch.id, *older.map(&:id))
      expect(File.exist?(File.join(tmpdir, "#{newest_real.id}.json"))).to be(true)
    end
  end

  describe ".sweep_if_due" do
    let(:marker) { File.join(tmpdir, described_class::MARKER) }

    def old_session
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages << { role: "user", content: "hi" }
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      data = JSON.parse(File.read(path))
      data["updated_at"] = (Time.now - 30 * 86_400).iso8601(3)
      File.write(path, JSON.generate(data))
      session
    end

    it "prunes with the settings and touches its marker, then waits out the interval" do
      old = old_session

      # Through SessionManager, as the web app and hub call it.
      expect(Samagotchi::SessionManager.retention_sweep_if_due(state_dir: tmpdir)[:deleted]).to eq([old.id])
      expect(File).to exist(marker)

      again = old_session
      expect(described_class.sweep_if_due(state_dir: tmpdir)).to be_nil
      expect(Samagotchi::Session.exist?(again.id, state_dir: tmpdir)).to be(true)

      File.utime(Time.now - 25 * 3600, Time.now - 25 * 3600, marker)
      expect(described_class.sweep_if_due(state_dir: tmpdir)[:deleted]).to eq([again.id])
    end

    it "sweeps again after session.sweep_interval_hours" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.sweep_interval_hours").and_return(1)
      FileUtils.touch(marker)
      File.utime(Time.now - 2 * 3600, Time.now - 2 * 3600, marker)
      old = old_session

      expect(described_class.sweep_if_due(state_dir: tmpdir)[:deleted]).to eq([old.id])
    end

    it "is nil with no state dir, and when the sweep fails" do
      expect(described_class.sweep_if_due(state_dir: File.join(tmpdir, "none"))).to be_nil

      allow(Samagotchi::Session).to receive(:list).and_raise(Errno::EACCES)
      expect(described_class.sweep_if_due(state_dir: tmpdir)).to be_nil
    end
  end

  describe ".prune settings" do
    it "reads session.retention_days, session.max_count and session.keep_status when not given" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.retention_days").and_return(3)
      allow(Samagotchi::Config).to receive(:get).with("session.max_count").and_return(7)
      allow(Samagotchi::Config).to receive(:get).with("session.keep_status").and_return("running, error")
      expect(described_class).to receive(:apply)
        .with(hash_including(days: 3, max_count: 7, keep_status: %w[running error])).and_return(deleted: [], kept: [], skipped: [])

      described_class.prune(state_dir: tmpdir, keep_status: "")
    end

    it "takes the caller's values over the settings" do
      expect(described_class).to receive(:apply)
        .with(hash_including(days: 2, max_count: 4, keep_status: ["idle"])).and_return(deleted: [], kept: [], skipped: [])

      described_class.prune(state_dir: tmpdir, days: "2", max_count: 4, keep_status: "idle")
    end
  end
end
