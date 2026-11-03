# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/live_versions"
require "samagotchi/web/auto_update"
require "samagotchi/web/update_check"
require "samagotchi/web/update_ops"
require "samagotchi/web/session_hub"

RSpec.describe Samagotchi::Web::AutoUpdate do
  def op_result(state, rows) = Samagotchi::Web::UpdateOps::Result.new(state: state, rows: rows)

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
  let(:result) { op_result("done", rows) }
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
      expect(check.auto_state).to have_attributes(version: version, from: Samagotchi::VERSION, phase: "done", pushed: true,
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
    let(:result) { op_result("failed", rows) }

    it "pushes the first failed row's status once and gives the release up" do
      auto_update.step
      auto_update.step

      expect(ops).to have_received(:install).once
      expect(notices).to eq([{ kind: "failed", version: version, detail: "failed (offline)", installed: false }])
      expect(check.auto_failed?(version)).to be(true)
      expect(check.auto_state).to have_attributes(phase: "failed", detail: "failed (offline)")
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
      allow(ops).to receive(:install).and_return(op_result("failed", [
        { "component" => "chi update", "status" => "failed (no such version)",
          "failed" => true, "kept" => [] }
      ]))
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
      op_result("done", [{ "session_id" => "a", "state" => "restarted" }, { "session_id" => "b", "state" => "skipped" }])
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
      expect(check.auto_state).to have_attributes(phase: "web", restarted: 1, left: 1, version: version,
                                                  at: now.iso8601)
    end

    it "records the web phase before the exec, which ends this process" do
      seen = nil
      allow(ops).to receive(:restart_web) do
        seen = check.auto_state.phase
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
      expect(check.auto_state).to have_attributes(phase: "workers", restarted: 2, left: 1)

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
      allow(ops).to receive(:restart_workers).and_return(op_result("done", [{ "session_id" => "a", "state" => "restarted" }]))
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
      expect(check.auto_state).to have_attributes(phase: "installed")

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
      expect(check.auto_state).to have_attributes(phase: "failed", pushed: true)
    end

    it "lets a preflight that a stop finds running end, then neither restarts chi web nor records it" do
      preflighting = Queue.new
      finish_preflight = Queue.new
      allow(preflight).to receive(:call) do
        preflighting << true
        finish_preflight.pop
        nil
      end
      runner = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight,
                                   clock: -> { now }, first: 0).start
      pop!(preflighting, "the preflight to start")
      stopping = Thread.new { runner.stop }
      begin
        expect(stopping).to be_alive # it waits for the preflight
      ensure
        finish_preflight << true
        join!(stopping, "the stop")
      end
      expect(ops).not_to have_received(:restart_web)
      expect(check.auto_state).to have_attributes(phase: "workers")
    end

    it "tries chi web again when another operation took the turn from it" do
      allow(ops).to receive(:restart_web).and_return(:busy, :started)
      auto_update.step
      expect(check.auto_state).to have_attributes(phase: "workers")

      auto_update.step
      expect(ops).to have_received(:restart_web).twice
      expect(check.auto_state).to have_attributes(phase: "web")
    end

    it "says so when asking for the restart couldn't start it" do
      allow(ops).to receive(:restart_web).and_return(:start_failed)
      auto_update.step

      expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
      expect(check.auto_state).to have_attributes(phase: "failed")
    end

    it "says so when chi web can't restart itself here" do
      allow(ops).to receive(:restart_web).and_return(:no_wrapper)
      auto_update.step

      expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
      expect(notices.first[:detail]).to include("no_wrapper")
      expect(check.auto_state).to have_attributes(phase: "failed")
    end

    it "takes a whole run through the real operations and the real file, a chi web restart between" do
      frames = []
      hub.subscribe(->(event) { frames << event.data if event.type == "chi_update" })
      allow(hub).to receive(:refresh_installed).and_return(version)
      allow(hub).to receive(:touch)
      manager = double("manager")
      allow(manager).to receive(:restart_session) do |id, **|
        Samagotchi::SessionManager::Restarted.new(session_id: id, from_version: "0.1.0", version: version)
      end
      real_ops = lambda do
        Samagotchi::Web::UpdateOps.new(hub: hub, manager: manager, state_dir: root, blocked: -> {},
                                       runner: ->(_argv, env:, progress:) { [rows.to_json, true] })
      end
      worker = ->(id) { Samagotchi::LiveVersions::Worker.new(session_id: id, version: "0.1.0", restart: true) }
      allow(Samagotchi::LiveVersions).to receive(:stale_workers).and_return([worker.call("quiet"), worker.call("fresh")])
      # Quiet for 10 minutes, and touched a minute before the install: the install waits for no quiet.
      summaries.push({ id: "quiet", status: "idle", updated_at: quiet_at }, { id: "fresh", status: "idle", updated_at: (now - 60).iso8601 })

      first_ops = real_ops.call
      first_ops.restart_web = -> { true }
      described_class.new(hub: hub, ops: first_ops, check: check, auto: auto, restart: restart, preflight: preflight, clock: -> { now }).step
      expect(notices).to be_empty

      # The exec: a new process reads the file, and "quiet" has moved over.
      stub_const("Samagotchi::VERSION", version)
      allow(Samagotchi::LiveVersions).to receive(:stale_workers).and_return([worker.call("fresh")])
      restarted_check = Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [release] }, clock: -> { now },
                                                         state_file: state_file, gem_spec: Object.new, bundler: false, gem_dir: root,
                                                         installed_versions: installed_versions)
      second_ops = real_ops.call
      seen_frames = frames.size
      described_class.new(hub: hub, ops: second_ops, check: restarted_check, auto: auto, restart: restart, clock: -> { now }).step
      expect(notices).to eq([{ kind: "updated", version: version, kept: 0, restarted: 1, left: 1 }])
      expect(restarted_check.auto_state).to have_attributes(phase: "retrying", restarted: 1, left: 1)
      expect(frames.size).to eq(seen_frames) # a pass that restarted nothing is off the page

      # "fresh" has been left alone for long enough.
      described_class.new(hub: hub, ops: second_ops, check: restarted_check, auto: auto, restart: restart, clock: -> { now + 600 }).step
      expect(restarted_check.auto_state).to have_attributes(phase: "done", restarted: 2, left: 0)
      expect(notices.size).to eq(1)
      expect(manager).to have_received(:restart_session).with("fresh", any_args).once
    end

    describe "the record read back from its file" do
      def reloaded_check
        Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [release] }, clock: -> { now },
                                         state_file: state_file, gem_spec: Object.new, bundler: false, gem_dir: root,
                                         installed_versions: installed_versions)
      end

      def after_restart(check)
        described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight, clock: -> { now })
      end

      it "tells the phone the workers the old chi web restarted too" do
        auto_update.step # 1 restarted, 1 skipped, then the exec
        stub_const("Samagotchi::VERSION", version)
        allow(ops).to receive(:restart_workers).and_return(op_result("done", [{ "session_id" => "b", "state" => "restarted" }]))

        after_restart(reloaded_check).step

        expect(notices).to contain_exactly(include(kind: "updated", restarted: 2, left: 0))
      end

      it "still tries the left workers of a run chi web was restarted in the middle of" do
        state = JSON.parse(File.read(state_file))
        state["auto"] = { "version" => version, "from" => "0.1.0", "at" => now.iso8601, "kept" => [], "phase" => "workers",
                          "workers" => { "restarted" => 1, "left" => 2 } }
        File.write(state_file, JSON.generate(state))

        after_restart(reloaded_check).step

        expect(ops).to have_received(:restart_workers).once
      end
    end

    describe "in the restarted chi web (a run on record at phase web)" do
      let(:record) do
        Samagotchi::Web::AutoUpdateRecord.new(version: version, from: "0.1.0", at: now.iso8601, kept: %w[a.md b.md], phase: "web",
                                              restarted: 3, left: 1)
      end
      let(:workers_result) { op_result("done", [{ "session_id" => "b", "state" => "restarted" }]) }

      before do
        check.save_auto(record)
        stub_const("Samagotchi::VERSION", version) # the restarted chi web runs the release
      end

      it "counts the workers once more and says chi updated, once" do
        auto_update.step
        auto_update.step

        expect(hub).to have_received(:scan).once
        expect(notices).to eq([{ kind: "updated", version: version, kept: 2, restarted: 4, left: 0 }])
        expect(check.auto_state).to have_attributes(phase: "done", pushed: true)
        expect(ops).not_to have_received(:restart_web)
        expect(ops).not_to have_received(:install)
      end

      describe "with workers still left after its pass" do
        let(:skipped_rows) { op_result("done", [{ "session_id" => "b", "state" => "skipped" }]) }
        let(:restarted_rows) { op_result("done", [{ "session_id" => "b", "state" => "restarted" }]) }

        def at(time, check: self.check, restart: self.restart)
          described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight, clock: -> { time })
        end

        def retrying_check
          Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [release] }, clock: -> { now },
                                           state_file: state_file, gem_spec: Object.new, bundler: false, gem_dir: root,
                                           installed_versions: installed_versions)
        end

        before { allow(ops).to receive(:restart_workers).and_return(skipped_rows) }

        it "says chi updated at once, and stays open to try them" do
          auto_update.step

          expect(notices).to eq([{ kind: "updated", version: version, kept: 2, restarted: 3, left: 1 }])
          expect(check.auto_state).to have_attributes(phase: "retrying", pushed: true, restarted: 3, left: 1)
        end

        it "tries them at each later step, says nothing more, and ends once none is left" do
          auto_update.step
          at(now + 300).step
          expect(ops).to have_received(:restart_workers).twice
          expect(check.auto_state).to have_attributes(phase: "retrying", left: 1)

          allow(ops).to receive(:restart_workers).and_return(restarted_rows)
          at(now + 600).step

          expect(check.auto_state).to have_attributes(phase: "done", restarted: 4, left: 0)
          expect(notices.size).to eq(1)

          at(now + 900).step
          expect(ops).to have_received(:restart_workers).exactly(3).times
        end

        it "ends when a worker has gone by itself (an idle exit)" do
          auto_update.step
          allow(ops).to receive(:restart_workers).and_return(op_result("done", []))
          at(now + 300).step

          expect(check.auto_state).to have_attributes(phase: "done", restarted: 3, left: 0)
          expect(notices.size).to eq(1)
        end

        it "keeps the idle rule at each later step" do
          auto_update.step
          captured = nil
          allow(ops).to receive(:restart_workers) do |select:, **|
            captured = select
            skipped_rows
          end
          later = now + 300
          summaries.push({ id: "quiet", status: "idle", updated_at: (later - 601).iso8601 },
                         { id: "fresh", status: "idle", updated_at: (later - 60).iso8601 },
                         { id: "running", status: "running", updated_at: (later - 601).iso8601 },
                         { id: "asking", status: "idle", updated_at: (later - 601).iso8601, pending_question: { id: "q" } })
          at(later).step

          workers = %w[quiet fresh running asking].map { |id| Samagotchi::LiveVersions::Worker.new(session_id: id, version: "0.1.0", restart: true) }
          expect(workers.select { |worker| captured.call(worker) }.map(&:session_id)).to eq(["quiet"])
        end

        it "asks that a pass with nothing to report stays off the page" do
          auto_update.step
          at(now + 300).step

          expect(ops).to have_received(:restart_workers).with(hash_including(quiet: true)).twice
        end

        it "waits for another operation, and tries again" do
          auto_update.step
          allow(ops).to receive(:restart_workers).and_return(:busy)
          at(now + 300).step

          expect(check.auto_state).to have_attributes(phase: "retrying", left: 1)
        end

        it "ends at RETRY_FOR without another pass, and says nothing more" do
          auto_update.step
          at(now + described_class::RETRY_FOR).step

          expect(ops).to have_received(:restart_workers).once
          expect(check.auto_state).to have_attributes(phase: "done", left: 1)
          expect(notices.size).to eq(1)
        end

        it "ends at RETRY_FOR though every pass raises" do
          auto_update.step
          allow(ops).to receive(:restart_workers).and_raise(IOError)
          expect { at(now + 300).step }.to raise_error(IOError)
          at(now + described_class::RETRY_FOR).step

          expect(check.auto_state).to have_attributes(phase: "done")
        end

        it "goes straight to done when the run is older than RETRY_FOR already" do
          at(now + described_class::RETRY_FOR).step

          expect(check.auto_state).to have_attributes(phase: "done", left: 1)
          expect(notices.size).to eq(1)
        end

        it "takes up again after chi web restarts mid-retry, without saying chi updated twice" do
          auto_update.step
          allow(ops).to receive(:restart_workers).and_return(restarted_rows)

          restarted = retrying_check
          expect(restarted.auto_state).to have_attributes(phase: "retrying", restarted: 3, left: 1)
          at(now + 300, check: restarted).step

          expect(restarted.auto_state).to have_attributes(phase: "done", restarted: 4, left: 0)
          expect(notices.size).to eq(1)
          expect(hub).to have_received(:scan).once
        end

        it "stops at once with update.restart: never" do
          auto_update.step
          at(now + 300, restart: "never").step

          expect(ops).to have_received(:restart_workers).once
          expect(check.auto_state).to have_attributes(phase: "done")
        end

        describe "and a newer release out" do
          let(:newer) { Gem::Version.new(version).bump.to_s }

          before do
            auto_update.step
            allow(check).to receive(:available).and_return(newer)
          end

          it "does not hold the install: the new run takes the workers over" do
            at(now + 300).step

            expect(ops).to have_received(:install).with(newer, wait: true, auto: true)
            expect(check.auto_state).to have_attributes(version: newer)
          end

          it "keeps the install's own gate, and goes on trying meanwhile" do
            summaries << { id: "a", status: "running" }
            at(now + 300).step

            expect(ops).not_to have_received(:install)
            expect(ops).to have_received(:restart_workers).twice
            expect(check.auto_state).to have_attributes(version: version, phase: "retrying")
          end

          it "goes on trying after giving that release up" do
            check.save_auto(check.auto_state, failed: newer)
            at(now + 300).step

            expect(ops).not_to have_received(:install)
            expect(check.auto_state).to have_attributes(version: version, phase: "retrying")
          end
        end
      end

      it "says chi web came back on another chi when it did not come back on the release" do
        stub_const("Samagotchi::VERSION", "0.0.1")
        auto_update.step

        expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
        expect(notices.first[:detail]).to include("0.0.1")
        expect(check.auto_state).to have_attributes(phase: "failed")
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

  describe "a step that raises" do
    it "keeps the thread, logs it, and installs at a later step" do
      failures = [IOError.new("hub hiccup")]
      allow(hub).to receive(:snapshot) do
        failure = failures.shift
        raise failure if failure

        summaries
      end
      installed = Queue.new
      allow(ops).to receive(:install) { (installed << true) && result }
      allow(Samagotchi::Log).to receive(:exception)
      runner = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, first: 0, poll: 0.01).start

      pop!(installed, "the install at the step after the raise")
      runner.stop

      expect(Samagotchi::Log).to have_received(:exception).with(:web, "auto_update_failed", an_instance_of(IOError)).once
    end

    it "waits the whole poll before the next one, however often it raises" do
      asked = Queue.new
      allow(hub).to receive(:snapshot) do
        asked << true
        raise IOError, "hub hiccup"
      end
      allow(Samagotchi::Log).to receive(:exception)
      runner = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, first: 0, poll: 3600).start
      thread = runner.instance_variable_get(:@thread)

      pop!(asked, "the first step")
      wait_for("the thread to wait for its next step") { thread.status == "sleep" }

      expect(thread).to be_alive
      expect(asked).to be_empty
      runner.stop
    end
  end

  describe "a record that can't be saved" do
    before { allow(check).to(receive(:save_auto).and_wrap_original { |_original, *_args, **_opts| raise Errno::ENOSPC }) }

    def saving_again = allow(check).to(receive(:save_auto).and_call_original)

    it "says a failed install once the record holds it, not at each try" do
      allow(ops).to receive(:install).and_return(op_result("failed", [{ "component" => "chi (gem)", "status" => "failed (x)",
                                                                        "failed" => true, "kept" => [] }]))
      expect { auto_update.step }.to raise_error(Errno::ENOSPC)
      expect(notices).to be_empty

      saving_again
      auto_update.step
      expect(notices.map { |notice| notice[:kind] }).to eq(["failed"])
    end

    it "says \"chi updated\" once" do
      allow(ops).to receive(:restart_workers).and_return(op_result("done", []))
      allow(hub).to receive(:scan)
      stub_const("Samagotchi::VERSION", version)
      saving_again
      check.save_auto(Samagotchi::Web::AutoUpdateRecord.new(version: version, at: now.iso8601, phase: "web"))
      runner = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: "idle", clock: -> { now })
      saved = 0
      allow(check).to receive(:save_auto).and_wrap_original do |original, *args, **opts|
        # The pass's own save goes through; the one that closes the run fails once.
        raise Errno::ENOSPC if args.first.phase == "done" && (saved += 1) == 1

        original.call(*args, **opts)
      end

      expect { runner.step }.to raise_error(Errno::ENOSPC)
      runner.step

      expect(notices.map { |notice| notice[:kind] }).to eq(["updated"])
    end
  end

  describe "a newer chi it didn't install" do
    let(:restart) { "idle" }
    let(:installed) { version }
    let(:hub_versions) { double("hub's installed versions") }
    let(:hub) do
      Samagotchi::Web::SessionHub.new(state_dir: root, update_auto: "install", update_restart: restart, installed_versions: hub_versions)
    end
    let(:clock_at) { [now] }
    let(:preflight) { double("preflight", call: nil) }
    let(:auto_update) do
      described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight, clock: -> { clock_at.first })
    end
    let(:workers_result) { op_result("done", []) }
    # The checker has nothing: the release is inside update.min_age_hours, or already installed.
    let(:release) { Samagotchi::GemUpdate::Release.new(version: version, created_at: now - 60, prerelease: false) }

    before do
      allow(hub_versions).to receive(:newest) { installed }
      allow(ops).to receive_messages(restart_workers: workers_result, restart_web: :started)
      allow(hub).to receive(:scan)
    end

    def later(seconds) = clock_at[0] += seconds

    # Seen at one step, adopted at the next.
    def settled_step
      auto_update.step
      later(described_class::POLL)
      auto_update.step
    end

    it "takes it up only once it has settled: chi update merges the bundles after the gem" do
      auto_update.step
      expect(check.auto_state).to be_nil
      expect(ops).not_to have_received(:restart_workers)

      later(described_class::SETTLE)
      auto_update.step

      expect(ops).not_to have_received(:install)
      expect(ops).to have_received(:restart_workers).once
      expect(preflight).to have_received(:call).with(installed)
      expect(ops).to have_received(:restart_web).once
      expect(check.auto_state).to have_attributes(version: installed, from: Samagotchi::VERSION, phase: "web", kept: [])
    end

    it "does nothing when what is installed is no newer than this chi" do
      allow(hub_versions).to receive(:newest).and_return(Samagotchi::VERSION)
      settled_step
      expect(check.auto_state).to be_nil
    end

    it "starts the settling over for another version" do
      auto_update.step
      later(described_class::SETTLE)
      newer = Gem::Version.new(version).bump.to_s
      allow(hub_versions).to receive(:newest).and_return(newer)
      auto_update.step
      expect(check.auto_state).to be_nil
      later(described_class::SETTLE)
      auto_update.step
      expect(check.auto_state).to have_attributes(version: newer)
    end

    it "leaves it alone with update.auto off" do
      described_class.new(hub: hub, ops: ops, check: check, auto: "off", restart: restart, clock: -> { clock_at.first }).tap do |off|
        off.step
        later(described_class::POLL)
        off.step
      end
      expect(check.auto_state).to be_nil
    end

    context "with update.restart: never" do
      let(:restart) { "never" }

      it "leaves it to the page's toast" do
        settled_step
        expect(check.auto_state).to be_nil
        expect(ops).not_to have_received(:restart_workers)
      end
    end

    it "leaves it alone while the install is blocked (a checkout's git pull, Bundler, an unwritable gem dir)" do
      allow(ops).to receive(:blocked_reason).and_return("checkout")
      settled_step
      expect(check.auto_state).to be_nil
    end

    it "waits while a turn runs, a question waits or another operation runs" do
      summaries.push({ id: "a", status: "running" })
      settled_step
      expect(check.auto_state).to be_nil

      summaries.replace([{ id: "a", status: "idle", pending_question: { id: "q" } }])
      later(described_class::POLL)
      auto_update.step
      expect(check.auto_state).to be_nil

      summaries.clear
      allow(ops).to receive(:running?).and_return(true)
      later(described_class::POLL)
      auto_update.step
      expect(check.auto_state).to be_nil

      allow(ops).to receive(:running?).and_return(false)
      later(described_class::POLL)
      auto_update.step
      expect(check.auto_state).to have_attributes(version: installed, phase: "web")
    end

    it "lets an available newer release go first: it installs and restarts onto the newest" do
      newer = Gem::Version.new(version).bump.to_s
      allow(check).to receive(:available).and_return(newer)
      allow(ops).to receive(:install).and_return(result)
      settled_step
      expect(ops).to have_received(:install).with(newer, wait: true, auto: true)
      expect(check.auto_state).to have_attributes(version: newer)
    end

    it "keeps a stamp the retry window can read back from the file" do
      allow(ops).to receive(:restart_workers).and_return(op_result("done", [{ "session_id" => "a", "state" => "skipped" }]))
      settled_step
      reread = Samagotchi::Web::UpdateCheck.new(hub: hub, enabled: false, auto: true, fetcher: -> { [] }, clock: -> { now },
                                                state_file: state_file, gem_spec: Object.new, bundler: false, gem_dir: root,
                                                installed_versions: installed_versions)
      expect(reread.auto_state.left_to_try?(clock_at.first + 60, described_class::RETRY_FOR)).to be(true)
    end

    it "takes the whole run to chi updated: the restarted chi web says it, once" do
      settled_step
      expect(notices).to be_empty

      stub_const("Samagotchi::VERSION", installed)
      restarted = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, clock: -> { clock_at.first })
      restarted.step
      restarted.step

      expect(notices).to eq([{ kind: "updated", version: installed, kept: 0, restarted: 0, left: 0 }])
      expect(check.auto_state).to have_attributes(phase: "done")
      expect(ops).to have_received(:restart_web).once
    end

    describe "what the page is told about offering the restarts" do
      def offers = hub.chi_state[:auto_offers]

      it "offers nothing while a run is on its way to doing them" do
        settled_step
        expect(offers).to be_nil
      end

      it "offers them when a held restart has waited long, and still adopts once it is free" do
        summaries.push({ id: "a", status: "idle", pending_question: { id: "q" } })
        auto_update.step
        later(described_class::HELD_FOR - 1)
        auto_update.step
        expect(offers).to be_nil

        later(1)
        auto_update.step
        expect(offers).to eq(installed)
        expect(check.auto_state).to be_nil

        summaries.clear
        later(described_class::POLL)
        auto_update.step
        expect(check.auto_state).to have_attributes(version: installed, phase: "web")
      end

      it "offers them at once, and tries no more, when the preflight fails" do
        allow(preflight).to receive(:call).and_return("no such chi")
        settled_step
        expect(offers).to eq(installed)
        expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])

        later(described_class::POLL)
        auto_update.step
        expect(notices.size).to eq(1)
        expect(preflight).to have_received(:call).once
      end

      it "fails once when a restart comes back on the old chi, with no loop" do
        settled_step
        again = described_class.new(hub: hub, ops: ops, check: check, auto: auto, restart: restart, preflight: preflight, clock: -> { clock_at.first })
        2.times do
          again.step
          later(described_class::POLL)
        end
        expect(notices.map { |notice| notice[:kind] }).to eq(["restart_failed"])
        expect(ops).to have_received(:restart_web).once
        expect(offers).to eq(installed)
      end

      it "offers them again in a restarted chi web from a closed run, ahead of the gate" do
        check.save_auto(Samagotchi::Web::AutoUpdateRecord.new(version: installed, from: "0.1.0", at: now.iso8601, phase: "failed"))
        summaries.push({ id: "a", status: "running" })
        auto_update.step
        expect(offers).to eq(installed)
        expect(ops).not_to have_received(:restart_workers)
      end

      it "says so in one chi frame" do
        frames = []
        hub.subscribe(->(event) { frames << event.data if event.type == "chi" && event.data[:auto_offers] })
        2.times { hub.auto_offer_restart(installed) }
        expect(frames.size).to eq(1)
      end
    end

    it "finishes a run this chi web is already on, with no second restart (Restart chi web by hand on the way)" do
      stub_const("Samagotchi::VERSION", installed)
      check.save_auto(Samagotchi::Web::AutoUpdateRecord.new(version: installed, from: "0.1.0", at: now.iso8601, phase: "workers"))

      auto_update.step

      expect(ops).not_to have_received(:restart_web)
      expect(notices).to eq([{ kind: "updated", version: installed, kept: 0, restarted: 0, left: 0 }])
      expect(check.auto_state).to have_attributes(phase: "done")
    end
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
