# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
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
