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

      expect(result).to eq(state: "done", rows: rows)
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

      expect(result[:state]).to eq("failed")
      expect(result[:rows].first).to include("component" => "chi update", "failed" => true,
                                             "status" => "failed (no such version)")
    end

    it "says a child that failed with rows failed, with those rows" do
      bad = [{ "component" => "chi (gem)", "status" => "failed (offline)", "failed" => true, "kept" => [] }]
      ops = described_class.new(hub: hub, state_dir: state_dir, runner: ->(*, **) { [bad.to_json, false] }, blocked: -> {})

      expect(ops.install("99.0.0", wait: true)).to eq(state: "failed", rows: bad)
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

      expect(result).to eq(state: "done", rows: [{ "session_id" => "one", "state" => "restarted",
                                                   "from_version" => "0.122.0", "version" => "99.0.0" }])
      expect(frames).to all(include(operation: "workers", auto: true))
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
