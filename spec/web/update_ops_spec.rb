# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/update_ops"
require "samagotchi/web/session_hub"

# The operations the routes (app_spec) and AutoUpdate ask for, asked directly.
RSpec.describe Samagotchi::Web::UpdateOps do
  let(:state_dir) { Dir.mktmpdir("update-ops-spec") }
  let(:installed) { double("installed versions", newest: "99.0.0") }
  let(:hub) { Samagotchi::Web::SessionHub.new(state_dir: state_dir, installed_versions: installed) }
  let(:events) { [] }
  let(:rows) { [{ "component" => "chi (gem)", "status" => "updated", "failed" => false, "kept" => ["a.md"] }] }
  let(:runner) { ->(_argv, env:, progress:) { [rows.to_json, true] } }
  let(:ops) { described_class.new(hub: hub, manager: manager, state_dir: state_dir, runner: runner, blocked: -> {}) }
  let(:manager) { double("manager") }

  before { hub.subscribe(->(event) { events << event }) }

  after do
    hub.stop
    FileUtils.rm_rf(state_dir)
  end

  def frames = events.select { |event| event.type == "chi_update" }.map(&:data)

  describe "#install" do
    it "waits for the child and answers its final state and rows, its frames marked automatic when asked" do
      result = ops.install("99.0.0", wait: true, auto: true)

      expect(result).to eq(described_class::Result.new(state: "done", rows: rows))
      expect(frames.map { |frame| frame[:state] }).to eq(%w[running done])
      expect(frames).to all(include(operation: "install", version: "99.0.0", auto: true))
      expect(ops).not_to be_running
    end

    it "answers :started at once without waiting, and :busy to a second operation while it runs" do
      gate = Queue.new
      slow = lambda do |_argv, env:, progress:|
        gate.pop
        [rows.to_json, true]
      end
      ops = described_class.new(hub: hub, state_dir: state_dir, runner: slow, blocked: -> {})

      expect(ops.install("99.0.0")).to eq(:started)
      expect(ops).to be_running
      expect(ops.install("99.0.1")).to eq(:busy)
      expect(ops.restart_workers).to eq(:busy)
      expect(ops.restart_web).to eq(:unavailable)
      gate << true
      wait_for("the install to end") { !ops.running? }
      expect(frames.last).to include(state: "done")
      expect(frames.last).not_to include(:auto)
    end

    it "answers a child that printed no rows as a failed result carrying the child's own words" do
      silent = lambda do |_argv, env:, progress:|
        progress.call("no such version")
        ["", false]
      end
      ops = described_class.new(hub: hub, state_dir: state_dir, runner: silent, blocked: -> {})

      result = ops.install("99.0.0", wait: true)

      expect(result.state).to eq("failed")
      expect(result.rows.first).to include("component" => "chi update", "failed" => true,
                                           "status" => "failed (no such version)")
    end

    it "says a child that failed with rows failed, with those rows" do
      bad = [{ "component" => "chi (gem)", "status" => "failed (offline)", "failed" => true, "kept" => [] }]
      ops = described_class.new(hub: hub, state_dir: state_dir, runner: ->(*, **) { [bad.to_json, false] }, blocked: -> {})

      expect(ops.install("99.0.0", wait: true)).to eq(described_class::Result.new(state: "failed", rows: bad))
    end

    it "looks at what is installed before it says done" do
      ops.install("99.0.0", wait: true)

      expect(hub.installed).to eq("99.0.0")
    end

    it "answers :start_failed and lets go when no thread starts" do
      allow(Thread).to receive(:new).and_raise(ThreadError)

      expect(ops.install("99.0.0")).to eq(:start_failed)
      expect(ops).not_to be_running
      expect(frames.last).to include(state: "failed", operation: "install")
    end
  end

  describe "the real chi update child" do
    let(:pid_file) { File.join(state_dir, "descendant.pid") }

    # A seam for the deadline: it passes once the child is up, so a loaded runner can't reach it early.
    def real_ops(script, deadline: nil)
      options = deadline ? { deadline: deadline, stop_grace: 0.2 } : { stop_grace: 0.2 }
      described_class.new(hub: hub, state_dir: state_dir, blocked: -> {}, **options).tap do |built|
        allow(built).to receive(:update_argv).and_return(["sh", "-c", script])
      end
    end

    def descendant = File.read(pid_file).strip.then { |text| text.empty? ? nil : Integer(text) }

    def started? = File.exist?(pid_file) && !descendant.nil?

    def deadline_passes_once_started
      lambda do |_child|
        wait_for("the child to start") { started? }
        nil
      end
    end

    # This example's own child, should it fail before the group is stopped.
    after { Process.kill("KILL", descendant) if started? && !process_gone?(descendant) }

    it "answers the child's rows, with its stderr as progress" do
      json = [{ component: "chi (gem)", status: "updated", failed: false, kept: [] }].to_json
      result = real_ops("echo working >&2; echo '#{json}'").install("99.0.0", wait: true)

      expect(result).to be_done
      expect(result.rows.first).to include("component" => "chi (gem)")
      expect(frames.map { |frame| frame[:progress] }).to include("working")
    end

    it "stops a child past the deadline, with what it started, and fails through the usual path" do
      stopped = real_ops("sleep 300 & echo $! > #{pid_file}; wait", deadline: deadline_passes_once_started)
      runner = Thread.new { stopped.install("99.0.0", wait: true) }

      join!(runner, "the install to give up on the hung child")

      expect(runner.value.state).to eq("failed")
      expect(runner.value.rows.first).to include("component" => "chi update", "failed" => true)
      expect(runner.value.rows.first["status"]).to include("stopped after #{described_class::UPDATE_TIMEOUT / 60} minutes")
      expect(frames.last).to include(state: "failed", operation: "install")
      expect(stopped).not_to be_running
      wait_for("the child's child to be gone") { process_gone?(descendant) }
      expect(stopped.install("99.0.1")).to eq(:started) # the operation is free again
    end

    it "kills a child that ignores TERM" do
      stubborn = real_ops(%(trap "" TERM; sleep 300 & echo $! > #{pid_file}; wait), deadline: deadline_passes_once_started)
      runner = Thread.new { stubborn.install("99.0.0", wait: true) }

      join!(runner, "the install to give up on the stubborn child")

      expect(runner.value.state).to eq("failed")
      wait_for("the child's child to be gone") { process_gone?(descendant) }
    end

    it "takes the rows of a child that exited while something it left holds its pipes" do
      json = [{ component: "chi (gem)", status: "updated", failed: false, kept: [] }].to_json
      runner = Thread.new do
        real_ops("sleep 300 & echo $! > #{pid_file}; echo '#{json}'").install("99.0.0", wait: true)
      end

      join!(runner, "the install to end")

      expect(runner.value).to be_done
    end
  end

  describe "#blocked_reason" do
    it "is the blocked seam's answer" do
      expect(described_class.new(hub: hub, blocked: -> { "bundler" }).blocked_reason).to eq("bundler")
    end
  end

  describe "#restart_workers" do
    it "restarts the stale workers and answers the final rows, its frames marked automatic when asked" do
      worker = Samagotchi::LiveVersions::Worker.new(session_id: "one", version: "0.122.0", restart: true)
      allow(Samagotchi::LiveVersions).to receive(:stale_workers).with("99.0.0", state_dir: state_dir).and_return([worker])
      allow(hub).to receive(:touch)
      allow(manager).to receive(:restart_session).with("one", state_dir: state_dir, client_id: Samagotchi::ClientId::WEB_RESTART)
        .and_return(Samagotchi::SessionManager::Restarted.new(session_id: "one", from_version: "0.122.0", version: "99.0.0"))

      result = ops.restart_workers(wait: true, auto: true)

      expect(result.rows).to eq([{ "session_id" => "one", "state" => "restarted",
                                   "from_version" => "0.122.0", "version" => "99.0.0" }])
      expect(result).to be_done
      expect(frames).to all(include(operation: "workers", auto: true))
    end

    it "leaves a worker its select refuses as a skipped row, without asking the worker to restart" do
      workers = %w[go stay].map do |id|
        Samagotchi::LiveVersions::Worker.new(session_id: id, version: "0.122.0", restart: true)
      end
      allow(Samagotchi::LiveVersions).to receive(:stale_workers).and_return(workers)
      allow(hub).to receive(:touch)
      allow(manager).to receive(:restart_session).with("go", state_dir: state_dir, client_id: Samagotchi::ClientId::WEB_RESTART)
        .and_return(Samagotchi::SessionManager::Restarted.new(session_id: "go", from_version: "0.122.0", version: "99.0.0"))

      result = ops.restart_workers(wait: true, select: ->(worker) { worker.session_id == "go" })

      expect(result).to be_done
      expect(result.rows.map { |row| row.values_at("session_id", "state") }).to eq([%w[go restarted], %w[stay skipped]])
      expect(result.rows.last).to include("reason" => "not_idle")
      expect(manager).not_to have_received(:restart_session).with("stay", any_args)
    end

    describe "quiet" do
      def worker(id) = Samagotchi::LiveVersions::Worker.new(session_id: id, version: "0.122.0", restart: true)

      before do
        allow(Samagotchi::LiveVersions).to receive(:stale_workers).and_return([worker("stay"), worker("go")])
        allow(hub).to receive(:touch)
        allow(manager).to receive(:restart_session)
          .and_return(Samagotchi::SessionManager::Restarted.new(session_id: "go", from_version: "0.122.0", version: "99.0.0"))
      end

      it "publishes nothing when no worker restarted, but answers the rows" do
        result = ops.restart_workers(wait: true, auto: true, select: ->(_worker) { false }, quiet: true)

        expect(result.rows.map { |row| row["state"] }).to eq(%w[skipped skipped])
        expect(frames).to be_empty
        expect(ops).not_to be_running
      end

      it "publishes nothing for a worker that refuses" do
        allow(manager).to receive(:restart_session).and_raise(Samagotchi::SessionManager::OwnedByTUI.new("go"))

        result = ops.restart_workers(wait: true, select: ->(_worker) { true }, quiet: true)

        expect(result.rows.map { |row| row["state"] }).to eq(%w[owned_by_tui owned_by_tui])
        expect(frames).to be_empty
      end

      it "publishes from the first restart on, and how it ended" do
        ops.restart_workers(wait: true, auto: true, select: ->(candidate) { candidate.session_id == "go" }, quiet: true)

        expect(frames.map { |frame| frame[:state] }).to eq(%w[running done])
        expect(frames.last[:rows].size).to eq(2)
      end

      it "publishes nothing when the pass itself fails" do
        allow(Samagotchi::LiveVersions).to receive(:stale_workers).and_raise(IOError)

        expect(ops.restart_workers(wait: true, quiet: true)).to have_attributes(state: "failed")
        expect(frames).to be_empty
      end

      it "logs the sessions the pass was working through, as restart_one logs its sid" do
        allow(Samagotchi::LiveVersions).to receive(:stale_workers)
          .and_return([worker("stay"), worker("go")])
        allow(Samagotchi::Log).to receive(:exception)

        expect(ops.restart_workers(wait: true, quiet: true, select: ->(_) { raise IOError, "the selection broke" }))
          .to have_attributes(state: "failed")
        expect(Samagotchi::Log).to have_received(:exception).with(
          :web, "worker_restart_failed", anything, sids: %w[stay go]
        )
      end
    end

    it "answers :start_failed when no thread starts" do
      allow(Thread).to receive(:new).and_raise(ThreadError)

      expect(ops.restart_workers).to eq(:start_failed)
      expect(ops).not_to be_running
    end
  end

  describe "#restart_web" do
    it "is unavailable without the restart lambda" do
      expect(ops).not_to be_restart_web
      expect(ops.restart_web).to eq(:unavailable)
    end

    it "holds the operation for good once the restart is asked, so nothing else starts" do
      ops.restart_web = -> { true }

      expect(ops.restart_web).to eq(:started)
      expect(ops.install("99.0.0")).to eq(:busy)
      expect(ops.restart_workers).to eq(:busy)
      expect(ops.restart_web).to eq(:busy)
    end

    it "answers :start_failed and lets go when asking for the restart raises, so later operations aren't refused for good" do
      ops.restart_web = -> { raise ThreadError, "can't alloc thread" }

      expect(ops.restart_web).to eq(:start_failed)
      expect(ops).not_to be_running
    end

    it "lets go when the restart is refused" do
      ops.restart_web = -> { :no_wrapper }
      expect(ops.restart_web).to eq(:no_wrapper)
      expect(ops).not_to be_running

      ops.restart_web = -> { false }
      expect(ops.restart_web).to eq(:requested)
      expect(ops).not_to be_running
    end
  end

  describe "#update_argv" do
    it "runs the wrapper under this Ruby without a chi home" do
      allow(Samagotchi::InstalledGem).to receive(:wrapper).and_return("/installed/bin/chi")

      expect(ops.update_argv("99.0.0", home: nil))
        .to eq([RbConfig.ruby, "/installed/bin/chi", "update", "--to", "99.0.0", "--no-desktop", "--json"])
    end
  end
end
