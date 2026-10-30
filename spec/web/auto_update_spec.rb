# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/live_versions"
require "samagotchi/web/auto_update"
require "samagotchi/web/update_check"
require "samagotchi/web/session_hub"

RSpec.describe Samagotchi::Web::AutoUpdate do
  let(:root) { Dir.mktmpdir("auto-update-spec") }
  let(:state_file) { File.join(root, "update_check.json") }
  let(:now) { Time.utc(2026, 10, 30, 12) }
  let(:version) { Gem::Version.new(Samagotchi::VERSION).bump.to_s }
  let(:hub) { Samagotchi::Web::SessionHub.new(state_dir: root, update_auto: "install") }
  let(:notices) { [] }
  let(:summaries) { [] }
  let(:installed_versions) { double("installed versions", newest: nil) }
  let(:release) { Samagotchi::GemUpdate::Release.new(version: version, created_at: now - (48 * 3600), prerelease: false) }
  let(:check) do
    Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [release] }, clock: -> { now },
                                     state_file: state_file, gem_spec: Object.new, bundler: false, gem_dir: root,
                                     installed_versions: installed_versions)
  end
  let(:rows) { [{ "component" => "chi (gem)", "status" => "updated", "failed" => false, "kept" => [] }] }
  let(:result) { { state: "done", rows: rows } }
  let(:ops) { double("ops", blocked_reason: nil, running?: false) }
  let(:auto) { "install" }
  let(:restart) { "never" }
  let(:auto_update) { described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart) }

  before do
    hub.subscribe(->(event) { notices << event.data if event.type == "chi_notice" })
    allow(hub).to receive(:snapshot) { summaries }
    allow(ops).to receive(:install).and_return(result)
    check.check
  end

  after do
    hub.stop
    FileUtils.rm_rf(root)
  end

  it "installs the release the checker found, waiting for it, with the frames marked automatic" do
    auto_update.step

    expect(ops).to have_received(:install).with(version, wait: true, auto: true)
  end

  it "does nothing with update.auto off" do
    described_class.new(hub: hub, ops: ops, check: check, auto: "off").step

    expect(ops).not_to have_received(:install)
  end

  it "starts no thread with update.auto off" do
    expect(described_class.new(hub: hub, ops: ops, check: check, auto: "off").start.instance_variable_get(:@thread)).to be_nil
  end

  it "does nothing when nothing is available" do
    allow(installed_versions).to receive(:newest).and_return(version)
    auto_update.step

    expect(ops).not_to have_received(:install)
  end

  it "does nothing while the install is blocked (a checkout, Bundler, an unwritable gem dir)" do
    allow(ops).to receive(:blocked_reason).and_return("bundler")
    auto_update.step

    expect(ops).not_to have_received(:install)
  end

  it "waits while another update operation runs" do
    allow(ops).to receive(:running?).and_return(true)
    auto_update.step

    expect(ops).not_to have_received(:install)
  end

  describe "the idle gate" do
    it "waits while a turn runs anywhere, and goes once none does" do
      summaries << { id: "a", status: "idle" } << { id: "b", status: "running" }
      auto_update.step
      expect(ops).not_to have_received(:install)

      summaries.pop
      auto_update.step
      expect(ops).to have_received(:install).once
    end

    it "waits while a question waits for an answer" do
      summaries << { id: "a", status: "idle", pending_question: { id: "q" } }
      auto_update.step

      expect(ops).not_to have_received(:install)
    end

    it "is not held by idle, stopped or errored sessions" do
      summaries << { id: "a", status: "idle" } << { id: "b", status: "stopped" } << { id: "c", status: "error" }
      auto_update.step

      expect(ops).to have_received(:install)
    end
  end

  describe "a done install" do
    let(:rows) do
      [{ "component" => "chi (gem)", "status" => "updated", "failed" => false, "kept" => [] },
       { "component" => "system bundle", "status" => "updated", "failed" => false, "kept" => ["a.md", "b.md"] },
       { "component" => "other", "status" => "updated", "failed" => false, "kept" => ["a.md"] }]
    end

    it "pushes once what was installed and how many files kept their edits, and records it" do
      auto_update.step

      expect(notices).to eq([{ kind: "installed", version: version, kept: 2 }])
      expect(check.auto_state).to include(version: version, from: Samagotchi::VERSION, phase: "done", pushed: true,
                                          kept: ["a.md", "b.md"])
    end

    it "installs the release once: a later step finds it on record" do
      auto_update.step
      auto_update.step

      expect(ops).to have_received(:install).once
      expect(notices.size).to eq(1)
    end

    it "installs once even if the checker still says it is available" do
      auto_update.step
      allow(check).to receive(:available).and_return(version)
      auto_update.step

      expect(ops).to have_received(:install).once
    end
  end

  describe "a failed install" do
    let(:rows) { [{ "component" => "chi (gem)", "status" => "failed (offline)\nmore", "failed" => true, "kept" => [] }] }
    let(:result) { { state: "failed", rows: rows } }

    it "pushes the first failed row's status once and gives the release up" do
      auto_update.step
      auto_update.step

      expect(ops).to have_received(:install).once
      expect(notices).to eq([{ kind: "failed", version: version, detail: "failed (offline)", installed: false }])
      expect(check.auto_failed?(version)).to be(true)
      expect(check.auto_state).to include(phase: "failed", detail: "failed (offline)")
    end

    it "stays given up on across a chi web restart, and tries a newer release" do
      auto_update.step
      restarted = Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [release] },
                                                   clock: -> { now }, state_file: state_file, gem_spec: Object.new,
                                                   bundler: false, gem_dir: root, installed_versions: installed_versions)
      described_class.new(hub: hub, ops: ops, check: restarted, auto: auto, restart: restart).step
      expect(ops).to have_received(:install).once

      newer = Gem::Version.new(version).bump.to_s
      allow(restarted).to receive(:available).and_return(newer)
      described_class.new(hub: hub, ops: ops, check: restarted, auto: auto, restart: restart).step
      expect(ops).to have_received(:install).with(newer, wait: true, auto: true)
    end

    it "says a failure that left the gem installed as such" do
      rows << { "component" => "system bundle", "status" => "failed (merge)", "failed" => true, "kept" => [] }
      rows[0] = rows[0].merge("failed" => false, "status" => "updated")
      auto_update.step

      expect(notices.first).to include(installed: true, detail: "failed (merge)")
    end

    it "uses the child's own words as the failure when it printed no rows" do
      allow(ops).to receive(:install).and_return(state: "failed", rows: [
        { "component" => "chi update", "status" => "failed (no such version)",
          "failed" => true, "kept" => [] }
      ])
      auto_update.step

      expect(notices.first).to include(detail: "failed (no such version)")
    end
  end

  it "restarts nothing after the install with update.restart: never" do
    allow(ops).to receive_messages(restart_workers: nil, restart_web: nil)
    auto_update.step

    expect(ops).not_to have_received(:restart_workers)
    expect(ops).not_to have_received(:restart_web)
  end

  describe "with update.restart: idle" do
    let(:restart) { "idle" }
    let(:workers_result) do
      { state: "done", rows: [{ "session_id" => "a", "state" => "restarted" }, { "session_id" => "b", "state" => "skipped" }] }
    end
    let(:preflight) { double("preflight", call: nil) }
    let(:auto_update) do
      described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight,
                          clock: -> { now })
    end
    let(:quiet_at) { (now - (11 * 60)).iso8601 }

    before do
      allow(ops).to receive_messages(restart_workers: workers_result, restart_web: :started)
      allow(hub).to receive(:scan)
    end

    it "restarts the workers, then chi web, and says nothing yet (the restarted chi web says it)" do
      order = []
      allow(ops).to receive(:restart_workers) { (order << :workers) && workers_result }
      allow(preflight).to receive(:call) { (order << :preflight) && nil }
      allow(ops).to receive(:restart_web) { (order << :web) && :started }

      auto_update.step

      expect(order).to eq(%i[workers preflight web])
      expect(preflight).to have_received(:call).with(version)
      expect(notices).to be_empty
      expect(check.auto_state).to include(phase: "web", workers: { restarted: 1, left: 1 }, version: version,
                                          at: now.iso8601)
    end

    it "records the web phase before the exec, which ends this process" do
      seen = nil
      allow(ops).to receive(:restart_web) do
        seen = check.auto_state[:phase]
        :started
      end
      auto_update.step

      expect(seen).to eq("web")
    end

    describe "which workers restart" do
      def worker(id) = Samagotchi::LiveVersions::Worker.new(session_id: id, version: "0.1.0", restart: true)

      it "takes an idle session quiet for 10 minutes or more, and no other" do
        captured = nil
        allow(ops).to receive(:restart_workers) do |select:, **|
          captured = select
          workers_result
        end
        # The sessions' state when the worker pass runs (after the install, which waited for no turn).
        allow(ops).to receive(:install) do
          summaries.push({ id: "quiet", status: "idle", updated_at: quiet_at },
                         { id: "edge", status: "idle", updated_at: (now - 600).iso8601 },
                         { id: "fresh", status: "idle", updated_at: (now - (9 * 60)).iso8601 },
                         { id: "running", status: "running", updated_at: quiet_at },
                         { id: "asking", status: "idle", updated_at: quiet_at, pending_question: { id: "q" } },
                         { id: "stamp-less", status: "idle" })
          result
        end
        auto_update.step

        expect(%w[quiet edge fresh running asking stamp-less unknown].select { |id| captured.call(worker(id)) })
          .to eq(%w[quiet edge])
      end
    end

    it "keeps chi web as it is while a turn runs, trying the workers again at each step until it ends" do
      # The turn starts after the install, which waited for none.
      allow(ops).to receive(:install) do
        summaries << { id: "a", status: "running" }
        result
      end
      auto_update.step
      auto_update.step

      expect(ops).to have_received(:restart_workers).twice
      expect(ops).not_to have_received(:restart_web)
      expect(check.auto_state).to include(phase: "workers", workers: { restarted: 2, left: 1 })

      summaries.clear
      auto_update.step
      expect(ops).to have_received(:restart_web).once
    end

    it "stops trying the left workers after a day, and goes on to chi web" do
      allow(ops).to receive(:install) do
        summaries << { id: "a", status: "running" }
        result
      end
      auto_update.step
      later = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight,
                                  clock: -> { now + (24 * 3600) + 1 })
      summaries.clear
      later.step

      expect(ops).to have_received(:restart_workers).once
      expect(ops).to have_received(:restart_web).once
    end

    it "goes straight to chi web when every worker restarted" do
      allow(ops).to receive(:restart_workers).and_return(state: "done", rows: [{ "session_id" => "a", "state" => "restarted" }])
      allow(ops).to receive(:install) do
        summaries << { id: "a", status: "running" }
        result
      end
      auto_update.step
      summaries.clear
      auto_update.step

      expect(ops).to have_received(:restart_workers).once
      expect(ops).to have_received(:restart_web).once
    end

    it "waits while another operation runs" do
      allow(ops).to receive(:restart_web).and_return(:busy)
      auto_update.step
      allow(ops).to receive(:running?).and_return(true)
      auto_update.step

      expect(ops).to have_received(:restart_workers).once
      expect(ops).to have_received(:restart_web).once
    end

    it "tries again when another operation took the turn from the worker pass" do
      allow(ops).to receive(:restart_workers).and_return(:busy, workers_result)
      auto_update.step
      expect(ops).not_to have_received(:restart_web)
      expect(check.auto_state).to include(phase: "installed")

      auto_update.step
      expect(ops).to have_received(:restart_web)
    end

    it "does not restart chi web when the preflight fails, pushes why once, and does not try again" do
      allow(preflight).to receive(:call).and_return("the new chi said \"boom\", not #{version}")
      auto_update.step
      auto_update.step

      expect(ops).not_to have_received(:restart_web)
      expect(preflight).to have_received(:call).once
      expect(notices).to eq([{ kind: "restart_failed", version: version, detail: "the new chi said \"boom\", not #{version}" }])
      expect(check.auto_state).to include(phase: "failed", pushed: true)
    end

    it "tries chi web again when another operation took the turn from it" do
      allow(ops).to receive(:restart_web).and_return(:busy, :started)
      auto_update.step
      expect(check.auto_state).to include(phase: "workers")

      auto_update.step
      expect(ops).to have_received(:restart_web).twice
      expect(check.auto_state).to include(phase: "web")
    end

    it "says so when chi web can't restart itself here" do
      allow(ops).to receive(:restart_web).and_return(:no_wrapper)
      auto_update.step

      expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
      expect(notices.first[:detail]).to include("no_wrapper")
      expect(check.auto_state).to include(phase: "failed")
    end

    describe "in the restarted chi web (a run on record at phase web)" do
      let(:record) do
        { version: version, from: "0.1.0", at: now.iso8601, kept: %w[a.md b.md], phase: "web", workers: { restarted: 3, left: 1 } }
      end
      let(:workers_result) { { state: "done", rows: [{ "session_id" => "b", "state" => "restarted" }] } }

      before do
        check.save_auto(record)
        stub_const("Samagotchi::VERSION", version) # the restarted chi web runs the release
      end

      it "counts the workers once more and says chi updated, once" do
        auto_update.step
        auto_update.step

        expect(hub).to have_received(:scan).once
        expect(notices).to eq([{ kind: "updated", version: version, kept: 2, restarted: 4, left: 0 }])
        expect(check.auto_state).to include(phase: "done", pushed: true)
        expect(ops).not_to have_received(:restart_web)
        expect(ops).not_to have_received(:install)
      end

      it "says chi web came back on another chi when it did not come back on the release" do
        stub_const("Samagotchi::VERSION", "0.0.1")
        auto_update.step

        expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
        expect(notices.first[:detail]).to include("0.0.1")
        expect(check.auto_state).to include(phase: "failed")
      end

      it "takes its first step soon, not after the full first wait" do
        stepped = Queue.new
        allow(ops).to receive(:restart_workers) { (stepped << true) && workers_result }
        thread_update = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, clock: -> { now },
                                            first: 3600, poll: 3600)
        stub_const("Samagotchi::Web::AutoUpdate::FIRST_RESTARTED", 0)

        thread_update.start
        expect(stepped.pop(timeout: 2)).to be(true)
        thread_update.stop
      end
    end
  end

  it "tries again at the next step when another operation took the turn first" do
    allow(ops).to receive(:install).and_return(:busy, result)
    auto_update.step
    expect(notices).to be_empty
    expect(check.auto_state).to be_nil

    auto_update.step
    expect(notices.size).to eq(1)
  end

  it "runs its steps on a thread until stopped" do
    stepped = Queue.new
    allow(ops).to receive(:install) { (stepped << true) && result }
    thread_update = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, first: 0, poll: 0.05)

    thread_update.start
    expect(stepped.pop(timeout: 2)).to be(true)
    thread_update.stop
    expect(thread_update.instance_variable_get(:@thread)).to be_nil
  end
end
